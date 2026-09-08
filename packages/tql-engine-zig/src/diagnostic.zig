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
};

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
    try std.testing.expectEqual(@as(u32, 4), joined.start_byte);
    try std.testing.expectEqual(@as(u32, 20), joined.end_byte);
    try std.testing.expectEqual(@as(u32, 0), joined.start_point.row);
    try std.testing.expectEqual(@as(u32, 1), joined.end_point.row);
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
    try std.testing.expectEqual(@as(usize, 2), sink.items().len);
    try std.testing.expectEqualStrings("parse", sink.items()[0].category.name());
    try std.testing.expectEqualStrings("unresolved-name", sink.items()[1].category.name());
    try std.testing.expectEqualStrings("second arg", sink.items()[1].message);
}
