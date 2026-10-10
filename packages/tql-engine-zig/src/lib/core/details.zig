//! What a symbol is, beyond its spelling.

const std = @import("std");
const classes = @import("classes.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

/// A scalar operator, named by an `op[...]` symbol. Desugaring synthesizes
/// one for each arithmetic and matching operator.
pub const Scalar = enum {
    match,
    not_match,
    add,
    subtract,
    multiply,
    divide,

    /// How the operator is written, and how its symbol is named.
    pub fn spelling(self: Scalar) []const u8 {
        return switch (self) {
            .match => "~",
            .not_match => "!~",
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
        };
    }
};

/// What a comparison primitive answers about its two operands.
pub const Comparison = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    /// The operands' `Ordering`.
    compare,

    /// What the comparison answers for operands that order `LT`, `EQ` and
    /// `GT`, in that order. Null for `compare`.
    pub fn answers(self: Comparison) ?[3]bool {
        return switch (self) {
            .eq => .{ false, true, false },
            .ne => .{ true, false, true },
            .lt => .{ true, false, false },
            .lte => .{ true, true, false },
            .gt => .{ false, false, true },
            .gte => .{ false, true, true },
            .compare => null,
        };
    }

    /// What the comparison answers for operands that order as `order`.
    ///
    /// Preconditions:
    /// - `self` is not `compare`.
    pub fn answer(self: Comparison, order: std.math.Order) bool {
        return self.answers().?[
            switch (order) {
                .lt => 0,
                .eq => 1,
                .gt => 2,
            }
        ];
    }

    /// The comparison that answers `wanted`, if there is one.
    pub fn answering(wanted: [3]bool) ?Comparison {
        for (std.enums.values(Comparison)) |c| {
            const given = c.answers() orelse continue;
            if (std.mem.eql(bool, &given, &wanted)) return c;
        }
        return null;
    }
};

/// The machine operation a primitive denotes.
pub const PrimOp = enum {
    text,
    kind,
    kind_name,
    is_named,
    is_extra,
    range,
    string_length,
    mod,
    toint,
    filename,
    parent,
    ancestors,
    children,
    named_children,
    descendants,
    named_descendants,
    children_of_kind,
    descendants_of_kind,
    of_kind,
    is_kind,
    eq_int,
    ne_int,
    lt_int,
    lte_int,
    gt_int,
    gte_int,
    compare_int,
    eq_string,
    ne_string,
    lt_string,
    lte_string,
    gt_string,
    gte_string,
    compare_string,
    eq_node,
    ne_node,
    eq_kind,
    ne_kind,

    /// Returns the name the prelude writes it by.
    pub fn spelling(self: PrimOp) []const u8 {
        return switch (self) {
            inline else => |primop| "%" ++ @tagName(primop),
        };
    }

    pub const Compared = struct {
        comparison: Comparison,
        /// The type of both operands.
        operands: types.Primitive,
    };

    /// What this primitive compares, if it is a comparison.
    pub fn compared(self: PrimOp) ?Compared {
        return switch (self) {
            .eq_int => .{ .comparison = .eq, .operands = .Int },
            .ne_int => .{ .comparison = .ne, .operands = .Int },
            .lt_int => .{ .comparison = .lt, .operands = .Int },
            .lte_int => .{ .comparison = .lte, .operands = .Int },
            .gt_int => .{ .comparison = .gt, .operands = .Int },
            .gte_int => .{ .comparison = .gte, .operands = .Int },
            .compare_int => .{ .comparison = .compare, .operands = .Int },
            .eq_string => .{ .comparison = .eq, .operands = .String },
            .ne_string => .{ .comparison = .ne, .operands = .String },
            .lt_string => .{ .comparison = .lt, .operands = .String },
            .lte_string => .{ .comparison = .lte, .operands = .String },
            .gt_string => .{ .comparison = .gt, .operands = .String },
            .gte_string => .{ .comparison = .gte, .operands = .String },
            .compare_string => .{ .comparison = .compare, .operands = .String },
            .eq_node => .{ .comparison = .eq, .operands = .Node },
            .ne_node => .{ .comparison = .ne, .operands = .Node },
            .eq_kind => .{ .comparison = .eq, .operands = .Kind },
            .ne_kind => .{ .comparison = .ne, .operands = .Kind },
            else => null,
        };
    }

    /// The primitive that makes `comparison` between two `operands`, if
    /// there is one.
    pub fn comparing(comparison: Comparison, operands: types.Primitive) ?PrimOp {
        const table = comptime blk: {
            var made = std.enums.EnumArray(types.Primitive, std.enums.EnumArray(Comparison, ?PrimOp))
                .initFill(.initFill(null));
            for (std.enums.values(PrimOp)) |primop| {
                const c = primop.compared() orelse continue;
                made.getPtr(c.operands).set(c.comparison, primop);
            }
            break :blk made;
        };
        return table.get(operands).get(comparison);
    }

    /// The single axis this one becomes when composed with a kind test, if
    /// there is one. `children` then `of_kind k` walks the same nodes as
    /// `children_of_kind k` without building the list between them.
    /// `named_children` then `of_kind k` does only when `k` is named.
    pub fn fusedWithKindTest(self: PrimOp) ?PrimOp {
        return switch (self) {
            .children, .named_children => .children_of_kind,
            .descendants, .named_descendants => .descendants_of_kind,
            else => null,
        };
    }
};

/// A built-in that denotes a Core term rather than a machine operation.
pub const Pseudo = enum {
    /// `\a b -> case a of { _ -> b }`.
    seq,

    /// Returns the name the prelude writes it by.
    pub fn spelling(self: Pseudo) []const u8 {
        return switch (self) {
            inline else => |pseudo| "%" ++ @tagName(pseudo),
        };
    }
};

/// What a synthesized symbol denotes. The payload is resolved during
/// desugaring and is unrecoverable from the spelling afterwards.
pub const Synthesized = union(enum) {
    /// `field[l]`, carrying the resolved grammar field ID.
    field: struct { name: []const u8, id: u16 },
    /// `op[+]` and friends.
    operator: Scalar,
    /// `record[l,...]`, labels in normalized order. The scheme is n-ary
    /// in the field count, so inference builds it from these rather than
    /// reading one off a table.
    record: []const []const u8,
    /// `select[l]`, reading the record field labelled `l`.
    select: []const u8,
};

/// What a primitive call runs.
pub const Operation = union(enum) {
    builtin: PrimOp,
    synthesized: Synthesized,
};

/// What a symbol is.
pub const Details = union(enum) {
    /// A binder or a written definition.
    vanilla,
    /// A built-in, denoting a machine operation.
    primop: PrimOp,
    /// A built-in replaced by the Core term it denotes wherever it is named.
    pseudo: Pseudo,
    /// Generated during compilation, denoting one the surface cannot name.
    synthesized: Synthesized,
    /// A data constructor, at its position in the datatype that declares it.
    constructor: struct { owner: symbols.TypeId, tag: u32 },
    /// A pattern synonym of `arity` parameters, matched by calling `matcher`.
    synonym: struct { arity: u32, matcher: symbols.SymbolId },
    /// Method `index` of `class`.
    method: struct { class: classes.ClassId, index: u32 },
    /// An instance's implementation of a method of its class. Defined like
    /// any global.
    instance_method,
    /// The global holding an instance's dictionary.
    instance: classes.InstanceId,
    /// `super[C,S]`, which takes a dictionary of `C` to one of `S`.
    selector,
};
