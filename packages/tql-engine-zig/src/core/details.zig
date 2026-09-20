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
};

/// What a synthesized symbol denotes. The payload is resolved during
/// desugaring and is unrecoverable from the spelling afterwards.
pub const Details = union(enum) {
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
};

pub const DetailsTable = symbols.SymbolTable(Details);
