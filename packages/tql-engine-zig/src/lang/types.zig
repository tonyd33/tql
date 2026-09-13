//! Type and scheme representation.

const std = @import("std");

/// A type variable, identified by its binding position in the enclosing
/// scheme's `forall`.
pub const TypeVar = u8;

/// An unknown standing for a type not yet determined.
pub const Meta = u32;

pub const Primitive = enum {
    Bool,
    Int,
    String,
    Regex,
    Node,
    Range,

    pub fn spelling(self: Primitive) []const u8 {
        return @tagName(self);
    }
};

pub const Type = union(enum) {
    variable: TypeVar,
    meta: Meta,
    primitive: Primitive,
    list: *const Type,
    record: []const Field,
    function: *const Arrow,

    pub const Field = struct {
        label: []const u8,
        type: *const Type,
    };

    pub const Arrow = struct {
        from: Type,
        to: Type,
    };

    pub fn format(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(w, false);
    }

    fn write(self: Type, w: *std.Io.Writer, parenthesize_arrow: bool) std.Io.Writer.Error!void {
        switch (self) {
            .variable => |index| try w.writeByte('a' + @as(u8, @intCast(index))),
            .meta => |id| try w.print("?{d}", .{id}),
            .primitive => |p| try w.writeAll(p.spelling()),
            .list => |element| {
                try w.writeByte('[');
                try element.write(w, false);
                try w.writeByte(']');
            },
            .record => |fields| {
                try w.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s}: ", .{f.label});
                    try f.type.write(w, false);
                }
                try w.writeByte('}');
            },
            .function => |arrow| {
                if (parenthesize_arrow) try w.writeByte('(');
                try arrow.from.write(w, true);
                try w.writeAll(" -> ");
                try arrow.to.write(w, false);
                if (parenthesize_arrow) try w.writeByte(')');
            },
        }
    }
};

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
};

pub const bool_type: Type = .{ .primitive = .Bool };
pub const int_type: Type = .{ .primitive = .Int };
pub const string_type: Type = .{ .primitive = .String };
pub const regex_type: Type = .{ .primitive = .Regex };
pub const node_type: Type = .{ .primitive = .Node };
pub const range_type: Type = .{ .primitive = .Range };

pub fn variable_type(index: TypeVar) Type {
    return .{ .variable = index };
}

pub fn list_type(comptime element: Type) Type {
    return .{ .list = &element };
}

pub fn func_type(comptime from: Type, comptime to: Type) Type {
    return .{ .function = &.{ .from = from, .to = to } };
}

/// `Filter a b` = `a -> [b]`.
pub fn filter_type(comptime input: Type, comptime output: Type) Type {
    return func_type(input, list_type(output));
}

pub fn store(allocator: std.mem.Allocator, t: Type) !*const Type {
    const slot = try allocator.create(Type);
    slot.* = t;
    return slot;
}

pub fn list(allocator: std.mem.Allocator, element: Type) !Type {
    return .{ .list = try store(allocator, element) };
}

pub fn func(allocator: std.mem.Allocator, from: Type, to: Type) !Type {
    const arrow = try allocator.create(Type.Arrow);
    arrow.* = .{ .from = from, .to = to };
    return .{ .function = arrow };
}

/// `Filter a b` = `a -> [b]`.
pub fn filter(allocator: std.mem.Allocator, input: Type, output: Type) !Type {
    return try func(allocator, input, try list(allocator, output));
}

test "filter notation expands to a function returning a list" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try filter_type(node_type, string_type).format(&buf.writer);
    try std.testing.expectEqualStrings("Node -> [String]", buf.written());
}

test "arrows are right-associative and group on the left" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const compose = comptime func_type(filter_type(variable_type(0), variable_type(1)), func_type(filter_type(variable_type(1), variable_type(2)), filter_type(variable_type(0), variable_type(2))));
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
    const eq: Scheme = .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Eq, .type = variable_type(0) }},
        .type = comptime func_type(variable_type(0), func_type(variable_type(0), bool_type)),
    };
    try eq.format(&buf.writer);
    try std.testing.expectEqualStrings("Eq a => a -> a -> Bool", buf.written());
}
