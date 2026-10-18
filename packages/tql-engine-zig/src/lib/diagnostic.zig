//! Spans and diagnostics, shared by the surface AST and everything downstream.

const std = @import("std");
const location = @import("location.zig");

const Point = location.Point;
const Range = location.Range;

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

/// A range of the source `source` names.
pub const Span = struct {
    /// Null for nodes that no source range corresponds to.
    range: ?Range,
    source: SourceId = .entry,

    pub const unknown: Span = .{ .range = null };

    /// Write the range, without the source.
    pub fn jsonStringify(self: Span, jws: anytype) !void {
        try jws.write(self.range);
    }

    /// Write the range, or `?` when there is none.
    pub fn format(self: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.range) |range| try range.format(w) else try w.writeByte('?');
    }

    /// Write the range's byte offsets, or `?` when there is none.
    pub fn sexpr(self: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.range) |range| try range.sexpr(w) else try w.writeByte('?');
    }

    /// The smallest span covering both operands. A span with no range
    /// covers nothing.
    ///
    /// Preconditions:
    /// - `a` and `b` are in the same source, or one has no range.
    pub fn join(a: Span, b: Span) Span {
        const ra = a.range orelse return b;
        const rb = b.range orelse return a;
        std.debug.assert(a.source == b.source);
        return .{ .range = ra.join(rb), .source = a.source };
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
    conflicting_export,
    type_mismatch,
    non_exhaustive,
    redundant_alternative,
    kind_mismatch,
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
            .conflicting_export => "conflicting-export",
            .type_mismatch => "type-mismatch",
            .non_exhaustive => "non-exhaustive",
            .redundant_alternative => "redundant-alternative",
            .kind_mismatch => "kind-mismatch",
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

/// A run of a diagnostic message.
pub const Part = union(enum) {
    text: []const u8,
    /// Quoted code, without delimiters.
    code: []const u8,
};

/// One reported problem. Its message is commentary and should not be treated
/// as part of the stable API.
pub const Diagnostic = struct {
    category: Category,
    span: Span,
    /// The message, in order.
    parts: []const Part,

    pub fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        freeRuns(allocator, self.parts);
        allocator.free(self.parts);
    }

    /// The message as plain text, with code in backticks.
    pub fn message(self: Diagnostic) Plain {
        return .{ .parts = self.parts };
    }

    /// Write the diagnostic followed by the lines of `source` its span covers,
    /// with the span underlined. `source` must be the one the span's
    /// `source` names.
    ///
    /// A span with no range gets neither location nor excerpt.
    pub fn render(
        self: Diagnostic,
        w: *std.Io.Writer,
        source: Source,
    ) std.Io.Writer.Error!void {
        try w.print("error[{s}]: {f}\n", .{ self.category.name(), self.message() });
        const range = self.span.range orelse return;

        const start = range.start_point;
        var end = range.end_point;
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

fn freeRuns(allocator: std.mem.Allocator, parts: []const Part) void {
    for (parts) |part| switch (part) {
        inline else => |run| allocator.free(run),
    };
}

/// Formats a message as plain text, each code part fenced as a CommonMark
/// code span: one backtick more than its longest run of backticks, padded
/// with a space when it starts or ends with one.
const Plain = struct {
    parts: []const Part,

    pub fn format(self: Plain, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.parts) |part| switch (part) {
            .text => |text| try w.writeAll(text),
            .code => |quoted| {
                const fence = longestBacktickRun(quoted) + 1;
                const pad = quoted.len > 0 and (quoted[0] == '`' or quoted[quoted.len - 1] == '`');
                try w.splatByteAll('`', fence);
                if (pad) try w.writeByte(' ');
                try w.writeAll(quoted);
                if (pad) try w.writeByte(' ');
                try w.splatByteAll('`', fence);
            },
        };
    }

    fn longestBacktickRun(text: []const u8) usize {
        var longest: usize = 0;
        var run: usize = 0;
        for (text) |c| {
            run = if (c == '`') run + 1 else 0;
            longest = @max(longest, run);
        }
        return longest;
    }
};

/// Mark `value` as code in a message. A tuple is one part, its elements
/// written in turn.
pub fn code(value: anytype) Code(@TypeOf(value)) {
    return .{ .value = value };
}

fn Code(comptime T: type) type {
    return struct { value: T };
}

/// A diagnostic message under construction.
pub const Message = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList(Part) = .empty,
    /// Text written since the last part ended.
    run: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) Message {
        return .{ .allocator = allocator, .run = .init(allocator) };
    }

    pub fn deinit(self: *Message) void {
        freeRuns(self.allocator, self.parts.items);
        self.parts.deinit(self.allocator);
        self.run.deinit();
    }

    /// Append each of the tuple `parts`: a `code` value as code, anything
    /// else as text. Text is a string, an integer, or a value with a `format`
    /// method.
    pub fn append(self: *Message, parts: anytype) std.mem.Allocator.Error!void {
        inline for (parts) |part| {
            if (comptime isCode(@TypeOf(part))) {
                try self.end(.text);
                try self.write(part.value);
                try self.end(.code);
            } else {
                try self.write(part);
            }
        }
    }

    /// Hands over the parts, leaving the message empty.
    pub fn toOwnedSlice(self: *Message) std.mem.Allocator.Error![]Part {
        try self.end(.text);
        return self.parts.toOwnedSlice(self.allocator);
    }

    fn write(self: *Message, value: anytype) std.mem.Allocator.Error!void {
        const T = @TypeOf(value);
        if (comptime isTuple(T)) {
            inline for (value) |element| try self.write(element);
            return;
        }
        self.run.writer.print(comptime spec(T), .{value}) catch return error.OutOfMemory;
    }

    /// End the run as a part of `kind`. An empty run is dropped.
    fn end(self: *Message, kind: std.meta.Tag(Part)) std.mem.Allocator.Error!void {
        if (self.run.written().len == 0) return;
        try self.parts.ensureUnusedCapacity(self.allocator, 1);
        const run = try self.run.toOwnedSlice();
        self.parts.appendAssumeCapacity(switch (kind) {
            .text => .{ .text = run },
            .code => .{ .code = run },
        });
    }

    fn isCode(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and @hasField(T, "value") and T == Code(@FieldType(T, "value"));
    }

    fn isTuple(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
    }

    fn spec(comptime T: type) []const u8 {
        switch (@typeInfo(T)) {
            .int, .comptime_int => return "{d}",
            .pointer => |p| {
                const elem = switch (p.size) {
                    .slice => p.child,
                    .one => switch (@typeInfo(p.child)) {
                        .array => |array| array.child,
                        else => void,
                    },
                    else => void,
                };
                if (elem == u8) return "{s}";
            },
            .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "format")) return "{f}",
            else => {},
        }
        @compileError("a message part must be a string, an integer or formattable, found " ++ @typeName(T));
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

    /// Report the message the tuple `parts` spells, as `Message.append` reads it.
    pub fn report(self: *Sink, category: Category, span: Span, parts: anytype) !void {
        var message: Message = .init(self.allocator);
        defer message.deinit();
        try message.append(parts);
        try self.add(category, span, &message);
    }

    /// Report what `message` holds, taking it over and leaving it empty.
    ///
    /// Preconditions:
    /// - `message` allocates with this sink's allocator.
    pub fn add(self: *Sink, category: Category, span: Span, message: *Message) !void {
        try self.diagnostics.ensureUnusedCapacity(self.allocator, 1);
        const parts = try message.toOwnedSlice();
        self.diagnostics.appendAssumeCapacity(.{ .category = category, .span = span, .parts = parts });
    }

    /// Reports each of `diagnostics` again, here.
    pub fn extend(self: *Sink, diagnostics: []const Diagnostic) !void {
        for (diagnostics) |d| {
            try self.diagnostics.ensureUnusedCapacity(self.allocator, 1);
            const parts = try self.allocator.alloc(Part, d.parts.len);
            var copied: usize = 0;
            errdefer {
                freeRuns(self.allocator, parts[0..copied]);
                self.allocator.free(parts);
            }
            for (d.parts, parts) |part, *copy| {
                copy.* = switch (part) {
                    inline else => |run, tag| @unionInit(Part, @tagName(tag), try self.allocator.dupe(u8, run)),
                };
                copied += 1;
            }
            self.diagnostics.appendAssumeCapacity(.{ .category = d.category, .span = d.span, .parts = parts });
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
        .span = .{ .range = .{ .start_byte = 1, .end_byte = 1, .start_point = start, .end_point = end } },
        .parts = &.{ .{ .text = "Expected " }, .{ .code = "Int" }, .{ .text = ", found " }, .{ .code = "String" }, .{ .text = "." } },
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
    const d: Diagnostic = .{ .category = .missing_main, .span = .unknown, .parts = &.{ .{ .text = "No " }, .{ .code = "main" }, .{ .text = "." } } };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try d.render(&buf.writer, .{ .name = null, .text = "f = 1;" });
    try std.testing.expectEqualStrings("error[missing-main]: No `main`.\n", buf.written());
}

fn expectParts(message: *Message, expected: []const Part) !void {
    const parts = try message.toOwnedSlice();
    defer (Diagnostic{ .category = .parse, .span = .unknown, .parts = parts }).deinit(std.testing.allocator);
    try std.testing.expectEqual(expected.len, parts.len);
    for (expected, parts) |want, got| {
        try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            inline else => |run, tag| try std.testing.expectEqualStrings(run, @field(got, @tagName(tag))),
        }
    }
}

test "append keeps text and code apart, with a backtick in code as content" {
    var message: Message = .init(std.testing.allocator);
    defer message.deinit();
    try message.append(.{ code("`("), " is not a valid regular expression" });
    try expectParts(&message, &.{ .{ .code = "`(" }, .{ .text = " is not a valid regular expression" } });
}

test "append joins text across calls and writes integers and code tuples" {
    var message: Message = .init(std.testing.allocator);
    defer message.deinit();
    try message.append(.{ "takes ", 2 });
    try message.append(.{ " arguments, as in ", code(.{ "f", " ", 1 }) });
    try expectParts(&message, &.{ .{ .text = "takes 2 arguments, as in " }, .{ .code = "f 1" } });
}

test "message fences code holding backticks with a longer run" {
    const d: Diagnostic = .{ .category = .parse, .span = .unknown, .parts = &.{ .{ .code = "`(" }, .{ .text = " or " }, .{ .code = "a `div` b" } } };
    const message = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{d.message()});
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("`` `( `` or ``a `div` b``", message);
}
