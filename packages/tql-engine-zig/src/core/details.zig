//! What a symbol is, beyond its spelling.

const symbols = @import("symbols.zig");

/// A scalar operator, which desugaring synthesizes an `op[...]` symbol for.
///
/// The surface has four more binary operators. `|`, `,`, `and` and `or`
/// desugar to prelude combinators and never reach here.
pub const Scalar = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    match,
    not_match,
    add,
    subtract,
    multiply,
    divide,
    modulo,

    /// How the operator is written, and how its symbol is named.
    pub fn spelling(self: Scalar) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .match => "~",
            .not_match => "!~",
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .modulo => "%",
        };
    }
};

/// The machine operation a primitive denotes.
pub const PrimOp = enum {
    text,
    kind,
    range,
    length,
    toint,
    filename,
    parent,
    ancestors,
    children,
    descendants,
    children_of_kind,
    descendants_of_kind,
    is_kind,
    field,
    operator,
    record,

    /// The single axis this one becomes when composed with a kind test, if
    /// there is one. `children` then `is_kind[k]` walks the same nodes as
    /// `children_of_kind[k]` without building the list between them.
    pub fn fusedWithKindTest(self: PrimOp) ?PrimOp {
        return switch (self) {
            .children => .children_of_kind,
            .descendants => .descendants_of_kind,
            else => null,
        };
    }
};

/// What a synthesized symbol denotes. The payload is resolved during
/// desugaring and is unrecoverable from the spelling afterwards.
pub const Synthesized = union(enum) {
    /// `is_kind[k]`, carrying the resolved grammar kind ID.
    kind_test: struct { name: []const u8, id: u16 },
    /// `descendants_of_kind[k]` or `children_of_kind[k]`, carrying the
    /// resolved grammar kind ID.
    kind_axis: struct { name: []const u8, id: u16, primop: PrimOp },
    /// `field[l]`, carrying the resolved grammar field ID.
    field: struct { name: []const u8, id: u16 },
    /// `op[+]` and friends.
    operator: Scalar,
    /// `record[l,...]`, labels in normalized order. The scheme is n-ary
    /// in the field count, so inference builds it from these rather than
    /// reading one off a table.
    record: []const []const u8,

    /// The machine operation this denotes.
    pub fn primop(self: Synthesized) PrimOp {
        return switch (self) {
            .kind_test => .is_kind,
            .kind_axis => |k| k.primop,
            .field => .field,
            .operator => .operator,
            .record => .record,
        };
    }
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
};
