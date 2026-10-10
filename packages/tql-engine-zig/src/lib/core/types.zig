//! Type and scheme representation.

const std = @import("std");
const classes = @import("classes.zig");
const datatypes = @import("datatypes.zig");

/// A type variable, identified by its binding position in the enclosing
/// scheme's `forall`.
pub const TypeVar = u8;

/// An unknown standing for a type not yet determined.
pub const Meta = u32;

/// A type the machine represents directly. `Prim` declares each as
/// `data Int = %Int;`.
pub const Primitive = enum(u32) {
    Int,
    String,
    Regex,
    Node,
    Kind,

    pub fn spelling(self: Primitive) []const u8 {
        return @tagName(self);
    }

    /// The datatype `Registry.reserveBuiltins` reserves for this primitive.
    pub fn id(self: Primitive) datatypes.TypeId {
        return @enumFromInt(@intFromEnum(self));
    }

    /// Returns the type that names this primitive's datatype.
    pub fn named(self: Primitive) Type {
        return switch (self) {
            .Int => int_type,
            .String => string_type,
            .Regex => regex_type,
            .Node => node_type,
            .Kind => kind_type,
        };
    }
};

/// The type of a type: `Type` for one with values, `Row` for the fields after
/// `|` in an open record, and `k -> k` for a constructor short of arguments.
pub const Kind = union(enum) {
    type,
    row,
    arrow: *const Arrow,
    /// An unknown during kind inference. A declared kind never holds one.
    meta: KindMeta,

    pub const Arrow = struct {
        from: Kind,
        to: Kind,
    };

    pub fn eql(a: Kind, b: Kind) bool {
        return switch (a) {
            .type, .row => std.meta.activeTag(a) == std.meta.activeTag(b),
            .arrow => |x| b == .arrow and x.from.eql(b.arrow.from) and x.to.eql(b.arrow.to),
            .meta => |id| b == .meta and b.meta == id,
        };
    }

    /// Returns `froms[0] -> .. -> froms[n-1] -> to`.
    pub fn arrows(allocator: std.mem.Allocator, froms: []const Kind, to: Kind) std.mem.Allocator.Error!Kind {
        var result = to;
        var i = froms.len;
        while (i > 0) {
            i -= 1;
            const arrow = try allocator.create(Arrow);
            arrow.* = .{ .from = froms[i], .to = result };
            result = .{ .arrow = arrow };
        }
        return result;
    }

    /// Format with each metavariable named `k`, `k1`, ... in order of first
    /// appearance. Share one `names` across every kind in a message.
    pub fn named(self: Kind, names: *KindNames) Named {
        return .{ .kind = self, .names = names };
    }

    pub const Named = struct {
        kind: Kind,
        names: *KindNames,

        pub fn format(self: Named, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.kind.write(w, false, self.names);
        }
    };

    fn write(self: Kind, w: *std.Io.Writer, parenthesize: bool, names: *KindNames) std.Io.Writer.Error!void {
        switch (self) {
            .type => try w.writeAll("Type"),
            .row => try w.writeAll("Row"),
            .arrow => |arrow| {
                if (parenthesize) try w.writeByte('(');
                try arrow.from.write(w, true, names);
                try w.writeAll(" -> ");
                try arrow.to.write(w, false, names);
                if (parenthesize) try w.writeByte(')');
            },
            .meta => |id| if (names.index(id)) |i| {
                if (i == 0) try w.writeByte('k') else try w.print("k{d}", .{i});
            } else try w.print("?k{d}", .{id}),
        }
    }
};

/// `count` kinds, each `Type`.
///
/// Preconditions:
/// - `count` is at most 256.
pub fn typeKinds(count: usize) []const Kind {
    return all_type_kinds[0..count];
}

const all_type_kinds = [_]Kind{.type} ** 256;

/// An unknown kind, numbered within one inference.
pub const KindMeta = u32;

pub const Type = union(enum) {
    variable: TypeVar,
    meta: Meta,
    /// A declared algebraic data type at its arguments. `[a]` is `List` at
    /// one argument and `Bool` is a nullary one.
    constructor: *const Constructed,
    record: Record,
    function: *const Arrow,
    /// A type written through an alias: `Range`, or `Named r`. Transparent
    /// to unification and classes, which see only `expansion`.
    alias: *const Aliased,
    /// A type variable or metavariable at an argument: `f a`. `f a b` is
    /// `(f a) b`.
    ///
    /// Invariants:
    /// - Its head is never a `.constructor` or `.alias` when `apply` builds
    ///   it. A metavariable at its head may since have been solved to one.
    application: *const Application,

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

    pub const Application = struct {
        head: Type,
        argument: Type,
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
            .variable, .meta => return self,
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
            .application => |a| {
                const node = try allocator.create(Application);
                node.* = .{ .head = try a.head.clone(allocator), .argument = try a.argument.clone(allocator) };
                return .{ .application = node };
            },
        }
    }

    fn write(self: Type, w: *std.Io.Writer, position: Position, names: ?*MetaNames) std.Io.Writer.Error!void {
        switch (self) {
            .variable => |index| try w.writeByte('a' + @as(u8, @intCast(index))),
            .meta => |id| if (if (names) |n| n.index(id) else null) |i| {
                try w.writeByte('a' + @as(u8, @intCast(i)));
            } else try w.print("?{d}", .{id}),
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
            .application => |a| {
                if (position == .argument) try w.writeByte('(');
                try a.head.write(w, .top, names);
                try w.writeByte(' ');
                try a.argument.write(w, .argument, names);
                if (position == .argument) try w.writeByte(')');
            },
        }
    }
};

/// Letters for metavariables within one message.
pub const MetaNames = Names(Meta);

/// Names for kind metavariables within one message.
pub const KindNames = Names(KindMeta);

/// Indices for metavariables within one message, handed out in order of
/// first appearance.
fn Names(comptime Id: type) type {
    return struct {
        seen: [26]Id = undefined,
        len: usize = 0,

        /// Returns the index `id` was given, giving it the next one if it has
        /// none. Null past the 26th.
        fn index(self: *@This(), id: Id) ?usize {
            if (std.mem.indexOfScalar(Id, self.seen[0..self.len], id)) |i| return i;
            if (self.len == self.seen.len) return null;
            self.seen[self.len] = id;
            self.len += 1;
            return self.len - 1;
        }
    };
}

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

/// `forall alpha_bar. constraints => tau`. `variables` holds the kind of
/// each bound variable, numbered from zero.
pub const Scheme = struct {
    variables: []const Kind = &.{},
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
            .variables = try allocator.dupe(Kind, self.variables),
            .constraints = constraints,
            .type = try self.type.clone(allocator),
        };
    }
};

pub const int_type = primitiveType(.Int);
pub const string_type = primitiveType(.String);
pub const regex_type = primitiveType(.Regex);
pub const node_type = primitiveType(.Node);
pub const kind_type = primitiveType(.Kind);

fn primitiveType(comptime p: Primitive) Type {
    const head: Type.Constructed = .{ .name = p.id(), .spelling = p.spelling(), .arguments = &.{} };
    return .{ .constructor = &head };
}

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

/// `head` applied to `argument`. A declared type takes `argument` as its next
/// argument, and an alias applies its expansion.
///
/// Preconditions:
/// - `head` has an arrow kind.
pub fn apply(allocator: std.mem.Allocator, head: Type, argument: Type) std.mem.Allocator.Error!Type {
    switch (head) {
        .constructor => |c| {
            const arguments = try allocator.alloc(Type, c.arguments.len + 1);
            @memcpy(arguments[0..c.arguments.len], c.arguments);
            arguments[c.arguments.len] = argument;
            const node = try allocator.create(Type.Constructed);
            node.* = .{ .name = c.name, .spelling = c.spelling, .arguments = arguments };
            return .{ .constructor = node };
        },
        .alias => |a| return try apply(allocator, a.expansion, argument),
        .variable, .meta, .application => {
            const node = try allocator.create(Type.Application);
            node.* = .{ .head = head, .argument = argument };
            return .{ .application = node };
        },
        .function, .record => unreachable,
    }
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

/// Whether `a` and `b` are the same type, node for node, looking through
/// aliases. A metavariable is equal only to itself.
pub fn eql(a: Type, b: Type) bool {
    if (a == .alias) return eql(a.alias.expansion, b);
    if (b == .alias) return eql(a, b.alias.expansion);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .variable => |v| v == b.variable,
        .meta => |id| id == b.meta,
        .constructor => |c| c.name == b.constructor.name and allEql(c.arguments, b.constructor.arguments),
        .function => |arrow| eql(arrow.from, b.function.from) and eql(arrow.to, b.function.to),
        .application => |x| eql(x.head, b.application.head) and eql(x.argument, b.application.argument),
        .record => |r| {
            const other = b.record;
            if (r.fields.len != other.fields.len) return false;
            for (r.fields, other.fields) |f, g| {
                if (!std.mem.eql(u8, f.label, g.label) or !eql(f.type.*, g.type.*)) return false;
            }
            const rest = r.rest orelse return other.rest == null;
            return if (other.rest) |o| eql(rest.*, o.*) else false;
        },
        .alias => unreachable,
    };
}

fn allEql(as: []const Type, bs: []const Type) bool {
    if (as.len != bs.len) return false;
    for (as, bs) |x, y| if (!eql(x, y)) return false;
    return true;
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
            .variable => |index| if (index < self.arguments.len)
                self.arguments[index]
            else
                @panic("a bound type variable outside its scheme"),
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
        .application => |a| {
            const applied = try rewrite(allocator, a.head, context);
            const argument = try rewrite(allocator, a.argument, context);
            if (std.meta.eql(applied, a.head) and std.meta.eql(argument, a.argument)) return head;
            return try apply(allocator, applied, argument);
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
