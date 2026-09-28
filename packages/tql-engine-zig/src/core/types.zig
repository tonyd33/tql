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
    Range,
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
    record: []const Field,
    function: *const Arrow,

    pub const Constructed = struct {
        name: datatypes.TypeId,
        /// Carried so a type can print without a registry in hand.
        spelling: []const u8,
        arguments: []const Type,
    };

    pub const Field = struct {
        label: []const u8,
        type: *const Type,
    };

    pub const Arrow = struct {
        from: Type,
        to: Type,
    };

    pub fn format(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(w, false, null);
    }

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
            try self.type.write(w, false, self.names);
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
            .record => |fields| {
                const copies = try allocator.alloc(Field, fields.len);
                for (fields, copies) |f, *copy| {
                    copy.* = .{ .label = f.label, .type = try store(allocator, try f.type.clone(allocator)) };
                }
                return .{ .record = copies };
            },
            .function => |arrow| return try func(
                allocator,
                try arrow.from.clone(allocator),
                try arrow.to.clone(allocator),
            ),
        }
    }

    fn write(self: Type, w: *std.Io.Writer, parenthesize_arrow: bool, names: ?*MetaNames) std.Io.Writer.Error!void {
        switch (self) {
            .variable => |index| try w.writeByte('a' + @as(u8, @intCast(index))),
            .meta => |id| if (names) |n| try n.write(id, w) else try w.print("?{d}", .{id}),
            .primitive => |p| try w.writeAll(p.spelling()),
            .constructor => |c| try writeConstructed(c, w, names),
            .record => |fields| {
                try w.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s}: ", .{f.label});
                    try f.type.write(w, false, names);
                }
                try w.writeByte('}');
            },
            .function => |arrow| {
                if (parenthesize_arrow) try w.writeByte('(');
                try arrow.from.write(w, true, names);
                try w.writeAll(" -> ");
                try arrow.to.write(w, false, names);
                if (parenthesize_arrow) try w.writeByte(')');
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
    if (c.arguments.len == 1 and std.mem.eql(u8, c.spelling, list_spelling)) {
        try w.writeByte('[');
        try c.arguments[0].write(w, false, names);
        try w.writeByte(']');
        return;
    }
    try w.writeAll(c.spelling);
    for (c.arguments) |argument| {
        try w.writeByte(' ');
        try argument.write(w, true, names);
    }
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
                try w.print("{s} ", .{c.class.spelling()});
                try c.type.format(w);
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
pub const range_type: Type = .{ .primitive = .Range };
pub const kind_type: Type = .{ .primitive = .Kind };

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
