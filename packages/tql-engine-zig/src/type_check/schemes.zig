//! Schemes for the synthesized symbol families.
//!
//! A synthesized symbol is one the desugarer generated rather than the user
//! wrote: `field[l]`, `op[+]`, `record[l,...]`. Stage 2
//! recorded what each was generated from in `desugar.Synthesis`, because
//! nothing downstream has the grammar.

const std = @import("std");
const primitives = @import("../primitives.zig");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;
const Substitution = @import("substitution.zig").Substitution;

/// A record with more labels than a `TypeVar` can index. `record` needs one
/// variable per field, so the ceiling is one below the `u8` maximum.
pub const max_record_fields = std.math.maxInt(types.TypeVar) - 1;

pub const Error = error{TooManyRecordFields} || Allocator.Error;

/// The scheme of a synthesized symbol.
///
/// `subst` is needed because `record`'s scheme is n-ary in its label
/// count and must be built at runtime; the other three are comptime constants
/// and touch it not at all.
pub fn schemeFor(subst: *Substitution, synthesized: core.Synthesized) Error!types.Scheme {
    return switch (synthesized) {
        // The field id is resolved and carried, and deliberately unused: a
        // field narrows the *value* but not yet the type.
        .field => try nodeFilter(subst),
        // Already written and unit-tested in `primitives.zig`; a property of
        // the operator, not of the interned id.
        .operator => |operator| try primitives.operatorScheme(
            subst.arena,
            subst.datatypes,
            operator,
        ),
        .record => |labels| try record(subst, labels),
    };
}

/// The scheme of a data constructor: its fields curried onto its datatype at
/// the datatype's own parameters.
///
/// `Cons : forall a. a -> [a] -> [a]`. Field types already name the
/// parameters as bound variables, so the result is built from them directly
/// and nothing is renumbered.
pub fn constructorScheme(
    arena: Allocator,
    declared: *const datatypes.Datatype,
    constructor: datatypes.Constructor,
    id: datatypes.TypeId,
) Allocator.Error!types.Scheme {
    const arguments = try arena.alloc(types.Type, declared.parameters);
    for (arguments, 0..) |*argument, i| argument.* = types.variable_type(@intCast(i));

    var result = try types.constructed(arena, id, declared.name, arguments);
    var i = constructor.fields.len;
    while (i > 0) {
        i -= 1;
        result = try types.func(arena, constructor.fields[i], result);
    }
    return .{ .quantified = declared.parameters, .type = result };
}

/// `Filter node node`: the scheme of `field[l]`.
fn nodeFilter(subst: *Substitution) !types.Scheme {
    return .{ .type = try subst.datatypes.filter(subst.arena, types.node_type, types.node_type) };
}

/// `record[l_1,...,l_n] : t_1 -> ... -> t_n -> {l_1: t_1, ..., l_n: t_n}`.
///
/// The one scheme whose *shape* depends on its symbol's metadata rather than
/// its identity, so it is constructed per symbol with no table row. Quantifies
/// one variable per field.
fn record(subst: *Substitution, labels: []const []const u8) Error!types.Scheme {
    if (labels.len > max_record_fields) return error.TooManyRecordFields;

    const fields = try subst.arena.alloc(types.Type.Field, labels.len);
    for (labels, fields, 0..) |label, *field, i| {
        field.* = .{
            .label = label,
            .type = try types.store(subst.arena, types.variable_type(@intCast(i))),
        };
    }

    // Built right to left: the record is the innermost, each field type
    // wrapping it in one more arrow.
    var result: types.Type = .{ .record = fields };
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        result = try types.func(subst.arena, types.variable_type(@intCast(i)), result);
    }

    return .{ .quantified = @intCast(labels.len), .type = result };
}
