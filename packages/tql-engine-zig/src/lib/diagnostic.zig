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

/// Which source text a span indexes into. The query being compiled is
/// `entry`; every other id is assigned by whoever parsed that source.
pub const SourceId = enum(u16) {
    entry = 0,
    _,
};

/// A source text as a diagnostic renders it.
pub const Source = struct {
    /// Null for a query given inline.
    name: ?[]const u8,
    text: []const u8,
};

/// Every source a compilation read besides the entry query, by `SourceId`.
///
/// Each source must outlive the table.
pub const Sources = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Source) = .empty,

    pub fn init(gpa: std.mem.Allocator) Sources {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sources) void {
        self.items.deinit(self.gpa);
    }

    pub fn add(self: *Sources, source: Source) !SourceId {
        try self.items.append(self.gpa, source);
        return @enumFromInt(self.items.items.len);
    }

    /// The source `id` names, where `entry` is the query's.
    pub fn get(self: *const Sources, id: SourceId, entry: Source) Source {
        if (id == .entry) return entry;
        return self.items.items[@intFromEnum(id) - 1];
    }

    pub fn clear(self: *Sources) void {
        self.items.clearRetainingCapacity();
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
    source: SourceId = .entry,

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
    ///
    /// Preconditions:
    /// - `a` and `b` are in the same source.
    pub fn join(a: Span, b: Span) Span {
        std.debug.assert(a.source == b.source);
        const start_first = a.start_byte <= b.start_byte;
        const end_first = a.end_byte >= b.end_byte;
        return .{
            .start_byte = if (start_first) a.start_byte else b.start_byte,
            .end_byte = if (end_first) a.end_byte else b.end_byte,
            .start_point = if (start_first) a.start_point else b.start_point,
            .end_point = if (end_first) a.end_point else b.end_point,
            .source = a.source,
        };
    }
};

pub const Category = enum {
    parse,
    unresolved_name,
    unresolved_module,
    unreadable_module,
    module_name_mismatch,
    import_cycle,
    grammar_mismatch,
    ambiguous_module,
    ambiguous_name,
    unknown_kind,
    supertype_kind,
    unknown_field,
    invalid_regex,
    symbol_collision,
    duplicate_signature,
    orphan_signature,
    duplicate_definition,
    shadowed_local,
    type_mismatch,
    over_application,
    unsatisfied_constraint,
    ambiguous_output,
    missing_main,
    main_type,
    main_parameters,
    signature_mismatch,
    cyclic_alias,
    cyclic_synonym,
    invalid_class,
    invalid_instance,
    orphan_instance,
    duplicate_instance,
    invalid_deriving,
    ambiguous_constraint,
    limit,

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .parse => "parse",
            .unresolved_name => "unresolved-name",
            .unresolved_module => "unresolved-module",
            .unreadable_module => "unreadable-module",
            .module_name_mismatch => "module-name-mismatch",
            .import_cycle => "import-cycle",
            .grammar_mismatch => "grammar-mismatch",
            .ambiguous_module => "ambiguous-module",
            .ambiguous_name => "ambiguous-name",
            .unknown_kind => "unknown-kind",
            .supertype_kind => "supertype-kind",
            .unknown_field => "unknown-field",
            .invalid_regex => "invalid-regex",
            .symbol_collision => "symbol-collision",
            .duplicate_signature => "duplicate-signature",
            .orphan_signature => "orphan-signature",
            .duplicate_definition => "duplicate-definition",
            .shadowed_local => "shadowed-local",
            .type_mismatch => "type-mismatch",
            .over_application => "over-application",
            .unsatisfied_constraint => "unsatisfied-constraint",
            .ambiguous_output => "ambiguous-output",
            .missing_main => "missing-main",
            .main_type => "main-type",
            .main_parameters => "main-parameters",
            .signature_mismatch => "signature-mismatch",
            .cyclic_alias => "cyclic-alias",
            .cyclic_synonym => "cyclic-synonym",
            .invalid_class => "invalid-class",
            .invalid_instance => "invalid-instance",
            .orphan_instance => "orphan-instance",
            .duplicate_instance => "duplicate-instance",
            .invalid_deriving => "invalid-deriving",
            .ambiguous_constraint => "ambiguous-constraint",
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
    /// with the span underlined. `source` must be the one the span's
    /// `source` names.
    ///
    /// A span equal to `Span.unknown` gets neither location nor excerpt.
    pub fn render(
        self: Diagnostic,
        w: *std.Io.Writer,
        source: Source,
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
        const gutter = std.math.log10_int(end.row + 1) + 1; // digit count

        try w.splatByteAll(' ', gutter);
        try w.writeAll("--> ");
        if (source.name) |name| try w.print("{s}:", .{name});
        try start.format(w);
        try w.writeByte('\n');

        var lines = std.mem.splitScalar(u8, source.text, '\n');
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

    /// Reports each of `diagnostics` again, here.
    pub fn extend(self: *Sink, diagnostics: []const Diagnostic) !void {
        for (diagnostics) |d| {
            const message = try self.allocator.dupe(u8, d.message);
            errdefer self.allocator.free(message);
            try self.diagnostics.append(self.allocator, .{ .category = d.category, .span = d.span, .message = message });
        }
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
    try d.render(&buf.writer, .{ .name = path, .text = source });
    try std.testing.expectEqualStrings(expected, buf.written());
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

test "render omits location and excerpt for an unknown span" {
    const d: Diagnostic = .{ .category = .missing_main, .span = .unknown, .message = "No `main`." };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try d.render(&buf.writer, .{ .name = null, .text = "f = 1;" });
    try std.testing.expectEqualStrings("error[missing-main]: No `main`.\n", buf.written());
}
