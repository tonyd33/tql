//! What a symbol is, beyond its spelling.

const std = @import("std");
const classes = @import("classes.zig");
const symbols = @import("symbols.zig");

/// A scalar operator, named by an `op[...]` symbol.
///
/// Desugaring synthesizes the arithmetic and matching operators. The
/// comparisons are the methods of `Eq` and `Ord` at primitive types, and what
/// the simplifier rewrites known comparisons to.
pub const Scalar = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    /// Two scalars to an `Ordering`.
    compare,
    match,
    not_match,
    add,
    subtract,
    multiply,
    divide,

    /// How the operator is written, and how its symbol is named.
    pub fn spelling(self: Scalar) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .compare => "compare",
            .match => "~",
            .not_match => "!~",
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
        };
    }

    /// What the comparison answers for operands that order `LT`, `EQ` and
    /// `GT`, in that order. Null for the other operators.
    pub fn answers(self: Scalar) ?[3]bool {
        return switch (self) {
            .eq => .{ false, true, false },
            .ne => .{ true, false, true },
            .lt => .{ true, false, false },
            .lte => .{ true, true, false },
            .gt => .{ false, false, true },
            .gte => .{ false, true, true },
            else => null,
        };
    }

    /// What the comparison answers for operands that order as `order`.
    ///
    /// Preconditions:
    /// - `self` is a comparison.
    pub fn answer(self: Scalar, order: std.math.Order) bool {
        return self.answers().?[
            switch (order) {
                .lt => 0,
                .eq => 1,
                .gt => 2,
            }
        ];
    }

    /// The comparison that answers `wanted`, if there is one.
    pub fn answering(wanted: [3]bool) ?Scalar {
        for (std.enums.values(Scalar)) |s| {
            const given = s.answers() orelse continue;
            if (std.mem.eql(bool, &given, &wanted)) return s;
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

    /// Returns the name the prelude writes it by.
    pub fn spelling(self: PrimOp) []const u8 {
        return switch (self) {
            inline else => |primop| "%" ++ @tagName(primop),
        };
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
