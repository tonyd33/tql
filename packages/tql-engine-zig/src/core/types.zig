//! Type and scheme representation.

const std = @import("std");
const datatypes = @import("datatypes.zig");

/// A type variable, identified by its binding position in the enclosing
/// scheme's `forall`.
pub const TypeVar = u8;

/// An unknown standing for a type not yet determined.
pub const Meta = u32;

pub const Primitive = enum {
    Int,
    String,
    Regex,
    Node,
    Kind,

    pub fn spelling(self: Primitive) []const u8 {
        return @tagName(self);
    }
};

pub const Type = union(enum) {
    variable: TypeVar,
    meta: Meta,
    primitive: Primitive,
    /// A declared algebraic data type at its arguments. `[a]` is `List` at
    /// one argument and `Bool` is a nullary one.
    constructor: *const Constructed,
    record: Record,
    function: *const Arrow,
    /// A type written through an alias: `Range`, or `Named r`. Transparent
    /// to unification and classes, which see only `expansion`.
    alias: *const Aliased,

    pub const Constructed = struct {
        name: datatypes.TypeId,
        /// Carried so a type can print without a registry in hand.
        spelling: []const u8,
        arguments: []const Type,
    };

    /// `{l: t, ...}`, or `{l: t, ... | r}` when `rest` stands for further
    /// fields.
    ///
    /// Invariants:
    /// - `fields` are sorted by label.
    /// - `rest` is a metavariable or bound variable, or resolves to another
    ///   record whose fields extend these.
    pub const Record = struct {
        fields: []const Field,
        rest: ?*const Type = null,
    };

    pub const Field = struct {
        label: []const u8,
        type: *const Type,

        pub fn order(a: []const u8, b: []const u8) std.math.Order {
            return std.mem.order(u8, a, b);
        }

        pub fn lessThan(_: void, a: Field, b: Field) bool {
            return order(a.label, b.label) == .lt;
        }
    };

    pub const Arrow = struct {
        from: Type,
        to: Type,
    };

    pub const Aliased = struct {
        spelling: []const u8,
        arguments: []const Type,
        /// The alias's body with `arguments` substituted for its parameters.
        expansion: Type,
    };

    pub fn format(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(w, .top, null);
    }

    /// Format as the argument of a type constructor or a class, parenthesized
    /// when it is an applied constructor or a function.
    pub fn operand(self: Type) Operand {
        return .{ .type = self };
    }

    pub const Operand = struct {
        type: Type,

        pub fn format(self: Operand, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.type.write(w, .argument, null);
        }
    };

    /// Where a type is written, which decides whether it needs parentheses.
    const Position = enum { top, arrow_from, argument };

    /// Format with metavariables named `a`, `b`, ... in order of first
    /// appearance. Share one `names` across every type in a message so a
    /// metavariable keeps its letter.
    pub fn named(self: Type, names: *MetaNames) Named {
        return .{ .type = self, .names = names };
    }

    pub const Named = struct {
        type: Type,
        names: *MetaNames,

        pub fn format(self: Named, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.type.write(w, .top, self.names);
        }
    };

    /// Copy every node of `self` into `allocator`. Labels and spellings are
    /// shared, not copied.
    pub fn clone(self: Type, allocator: std.mem.Allocator) std.mem.Allocator.Error!Type {
        switch (self) {
            .variable, .meta, .primitive => return self,
            .constructor => |c| {
                const arguments = try allocator.alloc(Type, c.arguments.len);
                for (c.arguments, arguments) |argument, *copy| copy.* = try argument.clone(allocator);
                const node = try allocator.create(Constructed);
                node.* = .{ .name = c.name, .spelling = c.spelling, .arguments = arguments };
                return .{ .constructor = node };
            },
            .record => |r| {
                const copies = try allocator.alloc(Field, r.fields.len);
                for (r.fields, copies) |f, *copy| {
                    copy.* = .{ .label = f.label, .type = try store(allocator, try f.type.clone(allocator)) };
                }
                const rest = if (r.rest) |t| try store(allocator, try t.clone(allocator)) else null;
                return .{ .record = .{ .fields = copies, .rest = rest } };
            },
            .function => |arrow| return try func(
                allocator,
                try arrow.from.clone(allocator),
                try arrow.to.clone(allocator),
            ),
            .alias => |a| {
                const arguments = try allocator.alloc(Type, a.arguments.len);
                for (a.arguments, arguments) |argument, *copy| copy.* = try argument.clone(allocator);
                return try aliased(allocator, a.spelling, arguments, try a.expansion.clone(allocator));
            },
        }
    }

    fn write(self: Type, w: *std.Io.Writer, position: Position, names: ?*MetaNames) std.Io.Writer.Error!void {
        switch (self) {
            .variable => |index| try w.writeByte('a' + @as(u8, @intCast(index))),
            .meta => |id| if (names) |n| try n.write(id, w) else try w.print("?{d}", .{id}),
            .primitive => |p| try w.writeAll(p.spelling()),
            .constructor => |c| {
                const parenthesize = position == .argument and c.arguments.len > 0 and !isListSugar(c);
                if (parenthesize) try w.writeByte('(');
                try writeConstructed(c, w, names);
                if (parenthesize) try w.writeByte(')');
            },
            .record => |r| {
                try w.writeByte('{');
                for (r.fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s}: ", .{f.label});
                    try f.type.write(w, .top, names);
                }
                if (r.rest) |rest| {
                    try w.writeAll(if (r.fields.len > 0) " | " else "| ");
                    try rest.write(w, .top, names);
                }
                try w.writeByte('}');
            },
            .function => |arrow| {
                if (position != .top) try w.writeByte('(');
                try arrow.from.write(w, .arrow_from, names);
                try w.writeAll(" -> ");
                try arrow.to.write(w, .top, names);
                if (position != .top) try w.writeByte(')');
            },
            .alias => |a| {
                const parenthesize = position == .argument and a.arguments.len > 0;
                if (parenthesize) try w.writeByte('(');
                try w.writeAll(a.spelling);
                for (a.arguments) |argument| {
                    try w.writeByte(' ');
                    try argument.write(w, .argument, names);
                }
                if (parenthesize) try w.writeByte(')');
            },
        }
    }
};

/// Letters for metavariables within one message.
pub const MetaNames = struct {
    seen: [26]Meta = undefined,
    len: usize = 0,

    /// Write the letter `id` was given, giving it the next one if it has none.
    /// Past `z`, write `?id`.
    fn write(self: *MetaNames, id: Meta, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const index = for (self.seen[0..self.len], 0..) |m, i| {
            if (m == id) break i;
        } else blk: {
            if (self.len == self.seen.len) return w.print("?{d}", .{id});
            self.seen[self.len] = id;
            self.len += 1;
            break :blk self.len - 1;
        };
        try w.writeByte('a' + @as(u8, @intCast(index)));
    }
};

fn writeConstructed(
    c: *const Type.Constructed,
    w: *std.Io.Writer,
    names: ?*MetaNames,
) std.Io.Writer.Error!void {
    if (isListSugar(c)) {
        try w.writeByte('[');
        try c.arguments[0].write(w, .top, names);
        try w.writeByte(']');
        return;
    }
    try w.writeAll(c.spelling);
    for (c.arguments) |argument| {
        try w.writeByte(' ');
        try argument.write(w, .argument, names);
    }
}

fn isListSugar(c: *const Type.Constructed) bool {
    return c.arguments.len == 1 and std.mem.eql(u8, c.spelling, list_spelling);
}

// For now, a closed constraint set is fine.
pub const TypeClassConstraint = struct {
    class: Class,
    type: Type,

    pub const Class = enum {
        Eq,
        Ord,
        Sized,
        Serial,

        pub fn spelling(self: Class) []const u8 {
            return @tagName(self);
        }
    };
};

/// `forall alpha_bar. constraints => tau`. `quantified` is the count of bound
/// variables, which are numbered from zero.
pub const Scheme = struct {
    quantified: u8 = 0,
    constraints: []const TypeClassConstraint = &.{},
    type: Type,

    pub fn format(self: Scheme, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.constraints.len > 0) {
            if (self.constraints.len > 1) try w.writeByte('(');
            for (self.constraints, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s} {f}", .{ c.class.spelling(), c.type.operand() });
            }
            if (self.constraints.len > 1) try w.writeByte(')');
            try w.writeAll(" => ");
        }
        try self.type.format(w);
    }

    /// Copy the type and every constraint into `allocator`.
    pub fn clone(self: Scheme, allocator: std.mem.Allocator) std.mem.Allocator.Error!Scheme {
        const constraints = try allocator.alloc(TypeClassConstraint, self.constraints.len);
        for (self.constraints, constraints) |c, *copy| {
            copy.* = .{ .class = c.class, .type = try c.type.clone(allocator) };
        }
        return .{
            .quantified = self.quantified,
            .constraints = constraints,
            .type = try self.type.clone(allocator),
        };
    }
};

pub const int_type: Type = .{ .primitive = .Int };
pub const string_type: Type = .{ .primitive = .String };
pub const regex_type: Type = .{ .primitive = .Regex };
pub const node_type: Type = .{ .primitive = .Node };
pub const kind_type: Type = .{ .primitive = .Kind };

/// The fields of `Point`, a position in the queried file.
pub const point_record: Type = .{ .record = .{ .fields = &.{
    .{ .label = "column", .type = &int_type },
    .{ .label = "row", .type = &int_type },
} } };

pub const point_type: Type = .{ .alias = &.{ .spelling = "Point", .arguments = &.{}, .expansion = point_record } };

/// The fields of `Range`, what `range` returns. Starts are inclusive and ends
/// exclusive.
pub const range_record: Type = .{ .record = .{ .fields = &.{
    .{ .label = "end_byte", .type = &int_type },
    .{ .label = "end_point", .type = &point_type },
    .{ .label = "start_byte", .type = &int_type },
    .{ .label = "start_point", .type = &point_type },
} } };

pub const range_type: Type = .{ .alias = &.{ .spelling = "Range", .arguments = &.{}, .expansion = range_record } };

pub fn variable_type(index: TypeVar) Type {
    return .{ .variable = index };
}

pub fn func_type(comptime from: Type, comptime to: Type) Type {
    return .{ .function = &.{ .from = from, .to = to } };
}

pub fn store(allocator: std.mem.Allocator, t: Type) !*const Type {
    const slot = try allocator.create(Type);
    slot.* = t;
    return slot;
}

/// The two names the compiler knows structurally. A type built before the
/// registry exists refers to them by spelling.
pub const list_spelling = "List";
pub const bool_spelling = "Bool";

/// A declared type at its arguments, copied into `allocator`.
pub fn constructed(
    allocator: std.mem.Allocator,
    name: datatypes.TypeId,
    spelling: []const u8,
    arguments: []const Type,
) !Type {
    const node = try allocator.create(Type.Constructed);
    node.* = .{
        .name = name,
        .spelling = spelling,
        .arguments = try allocator.dupe(Type, arguments),
    };
    return .{ .constructor = node };
}

pub fn func(allocator: std.mem.Allocator, from: Type, to: Type) !Type {
    const arrow = try allocator.create(Type.Arrow);
    arrow.* = .{ .from = from, .to = to };
    return .{ .function = arrow };
}

/// `expansion` written as `spelling` at `arguments`. Takes ownership of
/// `arguments`.
pub fn aliased(
    allocator: std.mem.Allocator,
    spelling: []const u8,
    arguments: []const Type,
    expansion: Type,
) !Type {
    const node = try allocator.create(Type.Aliased);
    node.* = .{ .spelling = spelling, .arguments = arguments, .expansion = expansion };
    return .{ .alias = node };
}

/// `t` with each bound variable replaced by `arguments` at its index.
/// Returns `t` itself when it has no variable, and shares every unchanged
/// subtree otherwise.
///
/// Preconditions:
/// - Every variable in `t` indexes `arguments`.
pub fn substitute(allocator: std.mem.Allocator, t: Type, arguments: []const Type) std.mem.Allocator.Error!Type {
    switch (t) {
        .variable => |index| return arguments[index],
        .meta, .primitive => return t,
        .constructor => |c| {
            const changed = try substituteAll(allocator, c.arguments, arguments) orelse return t;
            return try constructed(allocator, c.name, c.spelling, changed);
        },
        .record => |r| {
            var copies: ?[]Type.Field = null;
            for (r.fields, 0..) |f, i| {
                const replaced = try substitute(allocator, f.type.*, arguments);
                if (copies) |slots| {
                    slots[i] = .{ .label = f.label, .type = try store(allocator, replaced) };
                } else if (!std.meta.eql(replaced, f.type.*)) {
                    const slots = try allocator.alloc(Type.Field, r.fields.len);
                    @memcpy(slots[0..i], r.fields[0..i]);
                    slots[i] = .{ .label = f.label, .type = try store(allocator, replaced) };
                    copies = slots;
                }
            }
            var rest = r.rest;
            if (r.rest) |row| {
                const replaced = try substitute(allocator, row.*, arguments);
                if (!std.meta.eql(replaced, row.*)) rest = try store(allocator, replaced);
            }
            if (copies == null and rest == r.rest) return t;
            return .{ .record = .{ .fields = copies orelse r.fields, .rest = rest } };
        },
        .function => |arrow| {
            const from = try substitute(allocator, arrow.from, arguments);
            const to = try substitute(allocator, arrow.to, arguments);
            if (std.meta.eql(from, arrow.from) and std.meta.eql(to, arrow.to)) return t;
            return try func(allocator, from, to);
        },
        .alias => |a| {
            const changed = try substituteAll(allocator, a.arguments, arguments);
            const expansion = try substitute(allocator, a.expansion, arguments);
            if (changed == null and std.meta.eql(expansion, a.expansion)) return t;
            return try aliased(allocator, a.spelling, changed orelse a.arguments, expansion);
        },
    }
}

/// `substitute` over each of `ts`, or null when none changed. Allocates from
/// the first change on.
fn substituteAll(allocator: std.mem.Allocator, ts: []const Type, arguments: []const Type) std.mem.Allocator.Error!?[]Type {
    var copies: ?[]Type = null;
    for (ts, 0..) |each, i| {
        const replaced = try substitute(allocator, each, arguments);
        if (copies) |slots| {
            slots[i] = replaced;
        } else if (!std.meta.eql(replaced, each)) {
            const slots = try allocator.alloc(Type, ts.len);
            @memcpy(slots[0..i], ts[0..i]);
            slots[i] = replaced;
            copies = slots;
        }
    }
    return copies;
}

/// `[t]` at an arbitrary id. Printing keys on the spelling, not the id.
fn testList(arena: std.mem.Allocator, element: Type) !Type {
    return try constructed(arena, @enumFromInt(0), list_spelling, &.{element});
}

fn testFilter(arena: std.mem.Allocator, input: Type, output: Type) !Type {
    return try func(arena, input, try testList(arena, output));
}

test "filter notation expands to a function returning a list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const t = try testFilter(arena.allocator(), node_type, string_type);
    try t.format(&buf.writer);
    try std.testing.expectEqualStrings("Node -> [String]", buf.written());
}

test "arrows are right-associative and group on the left" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const compose = try func(t, try testFilter(t, variable_type(0), variable_type(1)), try func(t, try testFilter(t, variable_type(1), variable_type(2)), try testFilter(t, variable_type(0), variable_type(2))));
    try compose.format(&buf.writer);
    try std.testing.expectEqualStrings(
        "(a -> [b]) -> (b -> [c]) -> a -> [c]",
        buf.written(),
    );
}

test "a metavariable renders distinctly from a bound variable" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try (Type{ .meta = 3 }).format(&buf.writer);
    try std.testing.expectEqualStrings("?3", buf.written());

    buf.clearRetainingCapacity();
    try variable_type(3).format(&buf.writer);
    try std.testing.expectEqualStrings("d", buf.written());
}

test "constrained scheme renders its context" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const boolean = try constructed(t, @enumFromInt(1), bool_spelling, &.{});
    const eq: Scheme = .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Eq, .type = variable_type(0) }},
        .type = try func(t, variable_type(0), try func(t, variable_type(0), boolean)),
    };
    try eq.format(&buf.writer);
    try std.testing.expectEqualStrings("Eq a => a -> a -> Bool", buf.written());
}

test "an applied constructor is parenthesized as an argument" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const inner = try constructed(t, @enumFromInt(2), "Maybe", &.{int_type});
    const outer = try constructed(t, @enumFromInt(2), "Maybe", &.{inner});
    const nested = try constructed(t, @enumFromInt(2), "Maybe", &.{try testList(t, inner)});
    try buf.writer.print("{f}; {f}", .{ outer, nested });
    try std.testing.expectEqualStrings("Maybe (Maybe Int); Maybe [Maybe Int]", buf.written());
}

test "a constraint parenthesizes an applied constructor" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const maybe = try constructed(t, @enumFromInt(2), "Maybe", &.{variable_type(0)});
    const scheme: Scheme = .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Serial, .type = maybe }},
        .type = maybe,
    };
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("Serial (Maybe a) => Maybe a", buf.written());
}

test "an open record prints its row after a bar" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const open: Type = .{ .record = .{
        .fields = &.{.{ .label = "start_byte", .type = &variable_type(0) }},
        .rest = &variable_type(1),
    } };
    const only_row: Type = .{ .record = .{ .fields = &.{}, .rest = &variable_type(0) } };
    const empty: Type = .{ .record = .{ .fields = &.{} } };
    try buf.writer.print("{f}; {f}; {f}", .{ open, only_row, empty });
    try std.testing.expectEqualStrings("{start_byte: a | b}; {| a}; {}", buf.written());
}

test "a range prints by name and expands to a record of its bounds" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try buf.writer.print("{f}; {f}", .{ range_type, range_type.alias.expansion });
    try std.testing.expectEqualStrings(
        "Range; {end_byte: Int, end_point: Point, start_byte: Int, start_point: Point}",
        buf.written(),
    );
}

test "an applied alias is parenthesized as an argument" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const named = try aliased(t, "Named", try t.dupe(Type, &.{variable_type(0)}), int_type);
    try buf.writer.print("{f}", .{try testList(t, try constructed(t, @enumFromInt(2), "Maybe", &.{named}))});
    try std.testing.expectEqualStrings("[Maybe (Named a)]", buf.written());
}

test "substitution replaces an alias's arguments and its expansion together" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const named = try aliased(t, "Id", try t.dupe(Type, &.{variable_type(0)}), variable_type(0));
    const substituted = try substitute(t, named, &.{string_type});
    try buf.writer.print("{f}; {f}", .{ substituted, substituted.alias.expansion });
    try std.testing.expectEqualStrings("Id String; String", buf.written());
}

test "metavariables are named by first appearance across one message" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    var names: MetaNames = .{};
    const first = try testFilter(t, Type{ .meta = 477 }, Type{ .meta = 12 });
    const second = try func(t, Type{ .meta = 12 }, Type{ .meta = 900 });
    try buf.writer.print("{f} / {f}", .{ first.named(&names), second.named(&names) });
    try std.testing.expectEqualStrings("a -> [b] / b -> c", buf.written());
}
