//! Schemes for the four synthesized symbol families.
//!
//! A synthesized symbol is one the desugarer generated rather than the user
//! wrote: `is_kind[k]`, `field[l]`, `op[+]`, `record[l,...]`. Stage 2
//! recorded what each was generated from in `desugar.Synthesis`, because
//! nothing downstream has the grammar.
//!
//! Everything here goes through `schemeFor`, which takes the whole `Synthesis`
//! rather than pattern-matching to a constant. Two of the four arms ignore
//! their metadata today. Narrowed node types are why they still receive it:
//! under narrowing `is_kind[class_declaration]` would become
//! `Filter Node class_declaration` and `field[arguments]` would become
//! `Filter call_expression argument_list`, both derived from the resolved id
//! these arms already carry.

const std = @import("std");
const desugar = @import("../desugar.zig");
const datatypes = @import("../lang/datatypes.zig");
const primitives = @import("../lang/primitives.zig");
const datatypes_mod = @import("../lang/datatypes.zig");
const symbols = @import("../lang/symbols.zig");
const types = @import("../lang/types.zig");

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
pub fn schemeFor(subst: *Substitution, synthesis: desugar.Synthesis) Error!types.Scheme {
    return switch (synthesis) {
        // The kind id is resolved and carried, and deliberately unused: a kind
        // test narrows the *value* but not yet the type. W4 is where it starts
        // mattering.
        .kind_test => |k| try kindTest(subst, k.id),
        .field => |f| try fieldAccess(subst, f.id),
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

/// `is_kind[k] : Filter node node`.
fn kindTest(subst: *Substitution, id: u16) !types.Scheme {
    _ = id;
    return .{ .type = try subst.datatypes.filter(subst.arena, types.node_type, types.node_type) };
}

/// `field[l] : Filter node node`.
fn fieldAccess(subst: *Substitution, id: u16) !types.Scheme {
    _ = id;
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

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    subst: Substitution,
    interner: symbols.Interner,
    datatypes: datatypes_mod.Registry,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .arena = .init(gpa), .subst = undefined, .interner = try symbols.Interner.init(gpa), .datatypes = datatypes_mod.Registry.init(gpa) };
        try self.datatypes.declareStructural(&self.interner, self.arena.allocator());
        self.subst = Substitution.init(gpa, self.arena.allocator(), &self.datatypes);
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.subst.deinit();
        self.datatypes.deinit();
        self.interner.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn expectScheme(self: *Fixture, synthesis: desugar.Synthesis, expected: []const u8) !void {
        const scheme = try schemeFor(&self.subst, synthesis);
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try scheme.format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }
};

test "a kind test filters nodes to nodes" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        .{ .kind_test = .{ .name = "class_declaration", .id = 42 } },
        "Node -> [Node]",
    );
}

test "a field access filters nodes to nodes" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(.{ .field = .{ .name = "name", .id = 7 } }, "Node -> [Node]");
}

test "the resolved id does not change the scheme today" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Two different kinds, one scheme. Narrowing node types is the change
    // that would make this test wrong on purpose.
    try fix.expectScheme(
        .{ .kind_test = .{ .name = "class_declaration", .id = 1 } },
        "Node -> [Node]",
    );
    try fix.expectScheme(
        .{ .kind_test = .{ .name = "interface_declaration", .id = 2 } },
        "Node -> [Node]",
    );
}

test "an operator's scheme comes from the primitive table" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(.{ .operator = .eq }, "Eq a => a -> a -> Bool");
    try fix.expectScheme(.{ .operator = .lt }, "Ord a => a -> a -> Bool");
    try fix.expectScheme(.{ .operator = .add }, "Int -> Int -> Int");
    try fix.expectScheme(.{ .operator = .match }, "String -> Regex -> Bool");
}

test "a one-field record takes one field value and yields one record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        .{ .record = &.{"name"} },
        "a -> {name: a}",
    );
}

test "a two-field record takes one value per field" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        .{ .record = &.{ "kind", "name" } },
        "a -> b -> {kind: a, name: b}",
    );
}

test "a three-field record quantifies one variable per field" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemeFor(&fix.subst, .{ .record = &.{ "a", "b", "c" } });
    try testing.expectEqual(3, scheme.quantified);
}

test "an empty record takes no arguments and is an empty record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(.{ .record = &.{} }, "{}");
}

test "record labels keep the order the desugarer normalized them into" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Position i in the argument list is label i in the record, which is what
    // pairs `record[kind,name] p q` correctly. Unification matches records by
    // label, but the *scheme* must still pair them.
    try fix.expectScheme(
        .{ .record = &.{ "alpha", "beta" } },
        "a -> b -> {alpha: a, beta: b}",
    );
}

test "too many record fields is an error rather than a wrapped variable index" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, max_record_fields + 1);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    try testing.expectError(
        error.TooManyRecordFields,
        schemeFor(&fix.subst, .{ .record = labels }),
    );
}

test "a record at the field ceiling still builds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, max_record_fields);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    const scheme = try schemeFor(&fix.subst, .{ .record = labels });
    try testing.expectEqual(max_record_fields, scheme.quantified);
}

test "a record scheme instantiates to fresh metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemeFor(&fix.subst, .{ .record = &.{ "k", "n" } });
    const inst = try fix.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    try testing.expectEqualStrings(
        "?0 -> ?1 -> {k: ?0, n: ?1}",
        buf.written(),
    );
}
