//! Spans and diagnostics, shared by the surface AST and everything downstream.

const std = @import("std");

/// A position as a fixture writes it: zero-based internally, rendered
/// one-based.
pub const Point = struct {
    row: u32,
    column: u32,

    pub fn format(self: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.row + 1, self.column + 1 });
    }
};

/// A source range, half-open in bytes: `[start_byte, end_byte)`.
///
/// Points are carried alongside the byte offsets because error fixtures pin
/// `line:col`, and recovering that from a byte offset alone would mean
/// re-scanning the source at every diagnostic.
pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    start_point: Point,
    end_point: Point,

    /// For nodes that no source range corresponds to.
    pub const unknown: Span = .{
        .start_byte = 0,
        .end_byte = 0,
        .start_point = .{ .row = 0, .column = 0 },
        .end_point = .{ .row = 0, .column = 0 },
    };

    /// The `line:col-line:col` form the error fixtures are written in.
    pub fn format(self: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.start_point.format(w);
        try w.writeByte('-');
        try self.end_point.format(w);
    }

    /// Byte offsets only, for the AST s-expression goldens.
    pub fn sexpr(self: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.start_byte, self.end_byte });
    }

    /// The smallest span covering both operands.
    pub fn join(a: Span, b: Span) Span {
        const start_first = a.start_byte <= b.start_byte;
        const end_first = a.end_byte >= b.end_byte;
        return .{
            .start_byte = if (start_first) a.start_byte else b.start_byte,
            .end_byte = if (end_first) a.end_byte else b.end_byte,
            .start_point = if (start_first) a.start_point else b.start_point,
            .end_point = if (end_first) a.end_point else b.end_point,
        };
    }
};

pub const Category = enum {
    parse,
    unresolved_name,
    unknown_kind,
    unknown_field,
    invalid_regex,
    symbol_collision,
    duplicate_signature,
    orphan_signature,
    duplicate_definition,
    type_mismatch,
    over_application,
    unsatisfied_constraint,
    ambiguous_output,
    missing_main,
    main_type,
    main_parameters,
    signature_mismatch,
    limit,

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .parse => "parse",
            .unresolved_name => "unresolved-name",
            .unknown_kind => "unknown-kind",
            .unknown_field => "unknown-field",
            .invalid_regex => "invalid-regex",
            .symbol_collision => "symbol-collision",
            .duplicate_signature => "duplicate-signature",
            .orphan_signature => "orphan-signature",
            .duplicate_definition => "duplicate-definition",
            .type_mismatch => "type-mismatch",
            .over_application => "over-application",
            .unsatisfied_constraint => "unsatisfied-constraint",
            .ambiguous_output => "ambiguous-output",
            .missing_main => "missing-main",
            .main_type => "main-type",
            .main_parameters => "main-parameters",
            .signature_mismatch => "signature-mismatch",
            .limit => "limit",
        };
    }
};

/// One reported problem. `message` is commentary and should not be treated as
/// part of the stable API.
pub const Diagnostic = struct {
    category: Category,
    span: Span,
    message: []const u8,

    pub fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    /// Write the diagnostic followed by the lines of `source` its span covers,
    /// with the span underlined. `path` names `source` in the location line;
    /// pass null for a query given inline.
    ///
    /// A span equal to `Span.unknown` gets neither location nor excerpt.
    pub fn render(
        self: Diagnostic,
        w: *std.Io.Writer,
        source: []const u8,
        path: ?[]const u8,
    ) std.Io.Writer.Error!void {
        try w.print("error[{s}]: {s}\n", .{ self.category.name(), self.message });
        if (std.meta.eql(self.span, Span.unknown)) return;

        const start = self.span.start_point;
        var end = self.span.end_point;
        // A span ending at column 0 stops at the end of the line before it.
        if (end.row > start.row and end.column == 0) {
            end.row -= 1;
            end.column = std.math.maxInt(u32);
        }

        const shown_rows = end.row - start.row + 1;
        const gutter = digitCount(end.row + 1);

        try w.splatByteAll(' ', gutter);
        try w.writeAll("--> ");
        if (path) |p| try w.print("{s}:", .{p});
        try start.format(w);
        try w.writeByte('\n');

        var lines = std.mem.splitScalar(u8, source, '\n');
        var row: u32 = 0;
        while (row < start.row) : (row += 1) {
            if (lines.next() == null) return;
        }

        try w.splatByteAll(' ', gutter);
        try w.writeAll(" |\n");
        while (row <= end.row) : (row += 1) {
            const raw = lines.next() orelse break;
            const line = std.mem.trimEnd(u8, raw, "\r");

            const index = row - start.row;
            if (shown_rows > MAX_EXCERPT_ROWS and
                index >= MAX_EXCERPT_ROWS / 2 and index < shown_rows - MAX_EXCERPT_ROWS / 2)
            {
                if (index == MAX_EXCERPT_ROWS / 2) try w.writeAll("...\n");
                continue;
            }

            const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
            const from: usize = if (row == start.row) @min(start.column, line.len) else indent;
            const to: usize = if (row == end.row) @min(end.column, line.len) else line.len;
            const at_edge = row == start.row or row == end.row;

            try w.print("{d: >[1]} | {[2]s}\n", .{ row + 1, gutter, line });
            if (to <= from and !at_edge) continue;
            try w.splatByteAll(' ', gutter);
            try w.writeAll(" | ");
            for (line[0..from]) |c| {
                if (isContinuationByte(c)) continue;
                try w.writeByte(if (c == '\t') '\t' else ' ');
            }
            var carets: usize = 0;
            if (to > from) {
                for (line[from..to]) |c| {
                    if (!isContinuationByte(c)) carets += 1;
                }
            }
            try w.splatByteAll('^', @max(carets, 1));
            try w.writeByte('\n');
        }
    }
};

/// An excerpt longer than this many rows has its middle elided.
const MAX_EXCERPT_ROWS = 4;

fn digitCount(n: u32) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

fn isContinuationByte(c: u8) bool {
    return c & 0b1100_0000 == 0b1000_0000;
}

/// Collects diagnostics so a pass can report every problem it finds rather than
/// failing at the first.
pub const Sink = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Sink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Sink) void {
        for (self.diagnostics.items) |d| d.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn report(
        self: *Sink,
        category: Category,
        span: Span,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        errdefer self.allocator.free(message);
        try self.diagnostics.append(self.allocator, .{
            .category = category,
            .span = span,
            .message = message,
        });
    }

    pub fn items(self: *const Sink) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn hasErrors(self: *const Sink) bool {
        return self.diagnostics.items.len > 0;
    }

    /// Hands ownership of the collected diagnostics to the caller, leaving the
    /// sink empty.
    pub fn toOwnedSlice(self: *Sink) ![]Diagnostic {
        return self.diagnostics.toOwnedSlice(self.allocator);
    }
};

test "span join covers both operands" {
    const a: Span = .{
        .start_byte = 4,
        .end_byte = 8,
        .start_point = .{ .row = 0, .column = 4 },
        .end_point = .{ .row = 0, .column = 8 },
    };
    const b: Span = .{
        .start_byte = 10,
        .end_byte = 20,
        .start_point = .{ .row = 1, .column = 2 },
        .end_point = .{ .row = 1, .column = 12 },
    };
    const joined = Span.join(a, b);
    try std.testing.expectEqual(4, joined.start_byte);
    try std.testing.expectEqual(20, joined.end_byte);
    try std.testing.expectEqual(0, joined.start_point.row);
    try std.testing.expectEqual(1, joined.end_point.row);
}

test "spans render as one-based line:col" {
    const span: Span = .{
        .start_byte = 7,
        .end_byte = 13,
        .start_point = .{ .row = 0, .column = 7 },
        .end_point = .{ .row = 0, .column = 13 },
    };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try span.format(&buf.writer);
    try std.testing.expectEqualStrings("1:8-1:14", buf.written());
}

test "sink collects several diagnostics" {
    var sink = Sink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.report(.parse, Span.unknown, "first", .{});
    try sink.report(.unresolved_name, Span.unknown, "second {s}", .{"arg"});

    try std.testing.expect(sink.hasErrors());
    try std.testing.expectEqual(2, sink.items().len);
    try std.testing.expectEqualStrings("parse", sink.items()[0].category.name());
    try std.testing.expectEqualStrings("unresolved-name", sink.items()[1].category.name());
    try std.testing.expectEqualStrings("second arg", sink.items()[1].message);
}

fn expectRender(
    expected: []const u8,
    source: []const u8,
    path: ?[]const u8,
    start: Point,
    end: Point,
) !void {
    const d: Diagnostic = .{
        .category = .type_mismatch,
        .span = .{ .start_byte = 1, .end_byte = 1, .start_point = start, .end_point = end },
        .message = "Expected `Int`, found `String`.",
    };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try d.render(&buf.writer, source, path);
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "render underlines a span within one line" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:8
        \\  |
        \\1 | main = text + 1;
        \\  |        ^^^^
        \\
    , "main = text + 1;", null, .{ .row = 0, .column = 7 }, .{ .row = 0, .column = 11 });
}

test "render names the path in the location line" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> q.tql:2:3
        \\  |
        \\2 |   x
        \\  |   ^
        \\
    , "a\n  x\n", "q.tql", .{ .row = 1, .column = 2 }, .{ .row = 1, .column = 3 });
}

test "render widens the gutter to the last row shown" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\  --> 10:1
        \\   |
        \\10 | x
        \\   | ^
        \\
    , "\n\n\n\n\n\n\n\n\nx", null, .{ .row = 9, .column = 0 }, .{ .row = 9, .column = 1 });
}

test "render underlines every line of a multi-line span" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:8
        \\  |
        \\1 | main = do {
        \\  |        ^^^^
        \\2 |   return 1;
        \\  |   ^^^^^^^^^
        \\3 | };
        \\  | ^
        \\
    , "main = do {\n  return 1;\n};", null, .{ .row = 0, .column = 7 }, .{ .row = 2, .column = 1 });
}

test "render stops a span ending at column 0 on the line before" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:1
        \\  |
        \\1 | ab
        \\  | ^^
        \\
    , "ab\ncd", null, .{ .row = 0, .column = 0 }, .{ .row = 1, .column = 0 });
}

test "render elides the middle of a long span" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:1
        \\  |
        \\1 | a
        \\  | ^
        \\2 | b
        \\  | ^
        \\...
        \\5 | e
        \\  | ^
        \\6 | f
        \\  | ^
        \\
    , "a\nb\nc\nd\ne\nf", null, .{ .row = 0, .column = 0 }, .{ .row = 5, .column = 1 });
}

test "render keeps tabs so the underline lines up" {
    try expectRender(
        "error[type-mismatch]: Expected `Int`, found `String`.\n" ++
            " --> 1:3\n" ++
            "  |\n" ++
            "1 | \t x\n" ++
            "  | \t ^\n",
        "\t x",
        null,
        .{ .row = 0, .column = 2 },
        .{ .row = 0, .column = 3 },
    );
}

test "render counts one caret per character, not per byte" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:8
        \\  |
        \\1 | "é" + "ü"
        \\  |       ^^^
        \\
    , "\"é\" + \"ü\"", null, .{ .row = 0, .column = 7 }, .{ .row = 0, .column = 11 });
}

test "render marks a zero-width span with one caret" {
    try expectRender(
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:4
        \\  |
        \\1 | f x
        \\  |    ^
        \\
    , "f x", null, .{ .row = 0, .column = 3 }, .{ .row = 0, .column = 3 });
}

test "render omits location and excerpt for an unknown span" {
    const d: Diagnostic = .{ .category = .missing_main, .span = .unknown, .message = "No `main`." };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try d.render(&buf.writer, "f = 1;", null);
    try std.testing.expectEqualStrings("error[missing-main]: No `main`.\n", buf.written());
}
