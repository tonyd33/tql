//! Type and scheme representation.

const std = @import("std");
const classes = @import("classes.zig");
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
        position: Position = .top,

        pub fn format(self: Named, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.type.write(w, self.position, self.names);
        }
    };

    /// `named`, parenthesized as `operand` is.
    pub fn namedOperand(self: Type, names: *MetaNames) Named {
        return .{ .type = self, .names = names, .position = .argument };
    }

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

pub const TypeClassConstraint = struct {
    class: classes.ClassId,
    type: Type,
};

/// `forall alpha_bar. constraints => tau`. `quantified` is the count of bound
/// variables, which are numbered from zero.
pub const Scheme = struct {
    quantified: u8 = 0,
    constraints: []const TypeClassConstraint = &.{},
    type: Type,

    /// Format with each class spelled as `registry` declares it.
    pub fn named(self: Scheme, registry: *const classes.Registry) Named {
        return .{ .scheme = self, .registry = registry };
    }

    pub const Named = struct {
        scheme: Scheme,
        registry: *const classes.Registry,

        pub fn format(self: Named, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const constraints = self.scheme.constraints;
            if (constraints.len > 0) {
                if (constraints.len > 1) try w.writeByte('(');
                for (constraints, 0..) |c, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s} {f}", .{ self.registry.spelling(c.class), c.type.operand() });
                }
                if (constraints.len > 1) try w.writeByte(')');
                try w.writeAll(" => ");
            }
            try self.scheme.type.format(w);
        }
    };

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

/// The names the compiler knows structurally. A type built before the
/// registry exists refers to them by spelling.
pub const list_spelling = "List";
pub const bool_spelling = "Bool";
pub const ordering_spelling = "Ordering";

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

/// The arrow `t` is, looking through aliases.
pub fn arrowOf(t: Type) ?*const Type.Arrow {
    return switch (t) {
        .function => |arrow| arrow,
        .alias => |a| arrowOf(a.expansion),
        else => null,
    };
}

pub fn func(allocator: std.mem.Allocator, from: Type, to: Type) !Type {
    const arrow = try allocator.create(Type.Arrow);
    arrow.* = .{ .from = from, .to = to };
    return .{ .function = arrow };
}

/// Returns `froms[0] -> .. -> froms[n-1] -> to`.
pub fn arrows(allocator: std.mem.Allocator, froms: []const Type, to: Type) !Type {
    var result = to;
    var i = froms.len;
    while (i > 0) {
        i -= 1;
        result = try func(allocator, froms[i], result);
    }
    return result;
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
    return try rewrite(allocator, t, Arguments{ .arguments = arguments });
}

const Arguments = struct {
    arguments: []const Type,

    fn head(_: Arguments, t: Type) Type {
        return t;
    }

    fn record(_: Arguments, r: Type.Record) std.mem.Allocator.Error!Type.Record {
        return r;
    }

    fn replace(self: Arguments, t: Type) Type {
        return switch (t) {
            .variable => |index| self.arguments[index],
            else => t,
        };
    }
};

/// Rebuilds `t` with each variable and metavariable replaced, sharing every
/// unchanged subtree. Allocates only along a path where something changed,
/// and returns `t` itself when nothing did.
///
/// `context` supplies:
/// - `head(t) Type`: the node to walk in place of `t`, called on every node
/// - `record(r) !Type.Record`: the fields to walk in place of record `r`
/// - `replace(t) Type`: what a variable or metavariable becomes
pub fn rewrite(allocator: std.mem.Allocator, t: Type, context: anytype) std.mem.Allocator.Error!Type {
    const head = context.head(t);
    switch (head) {
        .variable, .meta => return context.replace(head),
        .primitive => return head,
        .constructor => |c| {
            const changed = try rewriteAll(allocator, c.arguments, context) orelse return head;
            return try constructed(allocator, c.name, c.spelling, changed);
        },
        .record => |written| {
            const r = try context.record(written);
            var copies: ?[]Type.Field = null;
            for (r.fields, 0..) |f, i| {
                const rewritten = try rewrite(allocator, f.type.*, context);
                if (copies) |slots| {
                    slots[i] = .{ .label = f.label, .type = try store(allocator, rewritten) };
                } else if (!std.meta.eql(rewritten, f.type.*)) {
                    const slots = try allocator.alloc(Type.Field, r.fields.len);
                    @memcpy(slots[0..i], r.fields[0..i]);
                    slots[i] = .{ .label = f.label, .type = try store(allocator, rewritten) };
                    copies = slots;
                }
            }
            var rest = r.rest;
            if (r.rest) |row| {
                const rewritten = try rewrite(allocator, row.*, context);
                if (!std.meta.eql(rewritten, row.*)) rest = try store(allocator, rewritten);
            }
            const result: Type.Record = .{ .fields = copies orelse r.fields, .rest = rest };
            if (std.meta.eql(result, written)) return head;
            return .{ .record = result };
        },
        .function => |arrow| {
            const from = try rewrite(allocator, arrow.from, context);
            const to = try rewrite(allocator, arrow.to, context);
            if (std.meta.eql(from, arrow.from) and std.meta.eql(to, arrow.to)) return head;
            return try func(allocator, from, to);
        },
        .alias => |a| {
            const changed = try rewriteAll(allocator, a.arguments, context);
            const expansion = try rewrite(allocator, a.expansion, context);
            if (changed == null and std.meta.eql(expansion, a.expansion)) return head;
            return try aliased(allocator, a.spelling, changed orelse a.arguments, expansion);
        },
    }
}

/// `rewrite` over each of `ts`, or null when none changed. Allocates from
/// the first change on.
fn rewriteAll(allocator: std.mem.Allocator, ts: []const Type, context: anytype) std.mem.Allocator.Error!?[]Type {
    var copies: ?[]Type = null;
    for (ts, 0..) |each, i| {
        const rewritten = try rewrite(allocator, each, context);
        if (copies) |slots| {
            slots[i] = rewritten;
        } else if (!std.meta.eql(rewritten, each)) {
            const slots = try allocator.alloc(Type, ts.len);
            @memcpy(slots[0..i], ts[0..i]);
            slots[i] = rewritten;
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
    const t = try testFilter(arena.allocator(), node_type, string_type);
    try std.testing.expectFmt("Node -> [String]", "{f}", .{t});
}

test "arrows are right-associative and group on the left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const compose = try func(t, try testFilter(t, variable_type(0), variable_type(1)), try func(t, try testFilter(t, variable_type(1), variable_type(2)), try testFilter(t, variable_type(0), variable_type(2))));
    try std.testing.expectFmt("(a -> [b]) -> (b -> [c]) -> a -> [c]", "{f}", .{compose});
}

test "a metavariable renders distinctly from a bound variable" {
    try std.testing.expectFmt("?3", "{f}", .{Type{ .meta = 3 }});

    try std.testing.expectFmt("d", "{f}", .{variable_type(3)});
}

test "constrained scheme renders its context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    var registry = classes.Registry.init(t);
    try registry.reserveBuiltins();
    const boolean = try constructed(t, @enumFromInt(1), bool_spelling, &.{});
    const eq: Scheme = .{
        .quantified = 1,
        .constraints = &.{.{ .class = .eq, .type = variable_type(0) }},
        .type = try func(t, variable_type(0), try func(t, variable_type(0), boolean)),
    };
    try std.testing.expectFmt("Eq a => a -> a -> Bool", "{f}", .{eq.named(&registry)});
}

test "an applied constructor is parenthesized as an argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const inner = try constructed(t, @enumFromInt(2), "Maybe", &.{int_type});
    const outer = try constructed(t, @enumFromInt(2), "Maybe", &.{inner});
    const nested = try constructed(t, @enumFromInt(2), "Maybe", &.{try testList(t, inner)});
    try std.testing.expectFmt("Maybe (Maybe Int); Maybe [Maybe Int]", "{f}; {f}", .{ outer, nested });
}

test "a constraint parenthesizes an applied constructor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    var registry = classes.Registry.init(t);
    try registry.reserveBuiltins();
    const maybe = try constructed(t, @enumFromInt(2), "Maybe", &.{variable_type(0)});
    const scheme: Scheme = .{
        .quantified = 1,
        .constraints = &.{.{ .class = .serial, .type = maybe }},
        .type = maybe,
    };
    try std.testing.expectFmt("Serial (Maybe a) => Maybe a", "{f}", .{scheme.named(&registry)});
}

test "an open record prints its row after a bar" {
    const open: Type = .{ .record = .{
        .fields = &.{.{ .label = "start_byte", .type = &variable_type(0) }},
        .rest = &variable_type(1),
    } };
    const only_row: Type = .{ .record = .{ .fields = &.{}, .rest = &variable_type(0) } };
    const empty: Type = .{ .record = .{ .fields = &.{} } };
    try std.testing.expectFmt("{start_byte: a | b}; {| a}; {}", "{f}; {f}; {f}", .{ open, only_row, empty });
}

test "a range prints by name and expands to a record of its bounds" {
    try std.testing.expectFmt(
        "Range; {end_byte: Int, end_point: Point, start_byte: Int, start_point: Point}",
        "{f}; {f}",
        .{ range_type, range_type.alias.expansion },
    );
}

test "an applied alias is parenthesized as an argument" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const named = try aliased(t, "Named", try t.dupe(Type, &.{variable_type(0)}), int_type);
    try std.testing.expectFmt("[Maybe (Named a)]", "{f}", .{try testList(t, try constructed(t, @enumFromInt(2), "Maybe", &.{named}))});
}

test "substitution replaces an alias's arguments and its expansion together" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    const named = try aliased(t, "Id", try t.dupe(Type, &.{variable_type(0)}), variable_type(0));
    const substituted = try substitute(t, named, &.{string_type});
    try std.testing.expectFmt("Id String; String", "{f}; {f}", .{ substituted, substituted.alias.expansion });
}

test "metavariables are named by first appearance across one message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = arena.allocator();
    var names: MetaNames = .{};
    const first = try testFilter(t, Type{ .meta = 477 }, Type{ .meta = 12 });
    const second = try func(t, Type{ .meta = 12 }, Type{ .meta = 900 });
    try std.testing.expectFmt("a -> [b] / b -> c", "{f} / {f}", .{ first.named(&names), second.named(&names) });
}
