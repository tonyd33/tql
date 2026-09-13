//! Schemes for the four synthesized symbol families.
//!
//! A synthesized symbol is one the desugarer generated rather than the user
//! wrote — `is_kind[k]`, `field[l]`, `op[+]`, `record_filter[l,...]`. Stage 2
//! recorded what each was generated from in `desugar.Synthesis`, because
//! nothing downstream has the grammar.
//!
//! Everything here goes through `schemeFor`, which takes the whole `Synthesis`
//! rather than pattern-matching to a constant. Two of the four arms ignore
//! their metadata today; narrowed node types are why they still receive it —
//! under narrowing `is_kind[class_declaration]` would become
//! `Filter Node class_declaration` and `field[arguments]` would become
//! `Filter call_expression argument_list`, both derived from the resolved id
//! these arms already carry.

const std = @import("std");
const desugar = @import("../desugar.zig");
const primitives = @import("../lang/primitives.zig");
const types = @import("../lang/types.zig");

const Allocator = std.mem.Allocator;
const Substitution = @import("substitution.zig").Substitution;

/// A record with more labels than a `TypeVar` can index. `record_filter` needs
/// one variable per field plus one for the shared input, so the ceiling is one
/// below the `u8` maximum.
pub const max_record_fields = std.math.maxInt(types.TypeVar) - 1;

pub const Error = error{TooManyRecordFields} || Allocator.Error;

/// The scheme of a synthesized symbol.
///
/// `subst` is needed because `record_filter`'s scheme is n-ary in its label
/// count and must be built at runtime; the other three are comptime constants
/// and touch it not at all.
pub fn schemeFor(subst: *Substitution, synthesis: desugar.Synthesis) Error!types.Scheme {
    return switch (synthesis) {
        // The kind id is resolved and carried, and deliberately unused: a kind
        // test narrows the *value* but not yet the type. W4 is where it starts
        // mattering.
        .kind_test => |k| kindTest(k.id),
        .field => |f| fieldAccess(f.id),
        // Already written and unit-tested in `primitives.zig`; a property of
        // the spelling, not of the interned id.
        .operator => |spelling| primitives.operatorScheme(spelling) orelse
            unreachable,
        .record_filter => |labels| try recordFilter(subst, labels),
    };
}

/// `is_kind[k] : Filter node node`.
///
/// The filter yields its input when the kind matches and nothing otherwise, so
/// input and output are the same type. Under W4 the output would narrow to the
/// kind `id` names.
fn kindTest(id: u16) types.Scheme {
    _ = id;
    return .{ .type = comptime types.filter_type(types.node_type, types.node_type) };
}

/// `field[l] : Filter node node`.
///
/// A known field absent from a particular node yields no output rather than
/// failing, which is why this is a filter and not a function — unlike the
/// projections, which are total.
fn fieldAccess(id: u16) types.Scheme {
    _ = id;
    return .{ .type = comptime types.filter_type(types.node_type, types.node_type) };
}

/// `record_filter[l_1,...,l_n] : Filter a t_1 -> ... -> Filter a t_n ->
/// Filter a {l_1: t_1, ..., l_n: t_n}`.
///
/// The one scheme whose *shape* depends on its symbol's metadata rather than
/// its identity, so it is constructed per symbol with no table row. Quantifies
/// `n + 1` variables: one per field type, plus the input every field filter
/// shares — which is what makes `{ a = kind, b = text }` require both fields to
/// read the same node.
///
/// Labels arrive normalized (sorted) from the desugarer, and the argument
/// order follows, so position `i` here is label `i` there.
fn recordFilter(subst: *Substitution, labels: []const []const u8) Error!types.Scheme {
    if (labels.len > max_record_fields) return error.TooManyRecordFields;

    // Variable 0 is the shared input; 1..n are the field types.
    const input = types.variable_type(0);

    const fields = try subst.arena.alloc(types.Type.Field, labels.len);
    for (labels, fields, 0..) |label, *field, i| {
        field.* = .{
            .label = label,
            .type = try types.store(subst.arena, types.variable_type(@intCast(i + 1))),
        };
    }

    // Built right to left: the result is the innermost, each field filter
    // wrapping it in one more arrow.
    var result = try types.filter(subst.arena, input, .{ .record = fields });
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        const field_filter = try types.filter(subst.arena, input, types.variable_type(@intCast(i + 1)));
        result = try types.func(subst.arena, field_filter, result);
    }

    return .{ .quantified = @intCast(labels.len + 1), .type = result };
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    subst: Substitution,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .arena = .init(gpa), .subst = undefined };
        self.subst = Substitution.init(gpa, self.arena.allocator());
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.subst.deinit();
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

    try fix.expectScheme(.{ .operator = "=" }, "Eq a => a -> a -> Bool");
    try fix.expectScheme(.{ .operator = "<" }, "Ord a => a -> a -> Bool");
    try fix.expectScheme(.{ .operator = "+" }, "Int -> Int -> Int");
    try fix.expectScheme(.{ .operator = "~" }, "String -> Regex -> Bool");
}

test "a one-feld record flter takes one flter and yelds one record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        .{ .record_filter = &.{"name"} },
        "(a -> [b]) -> a -> [{name: b}]",
    );
}

test "a two-field record filter shares one input across both fields" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `a` appears in both argument filters: `{ k = kind, n = .name | text }`
    // reads one node twice, and cannot mix inputs.
    try fix.expectScheme(
        .{ .record_filter = &.{ "kind", "name" } },
        "(a -> [b]) -> (a -> [c]) -> a -> [{kind: b, name: c}]",
    );
}

test "a three-field record filter quantifies one variable per field plus the input" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemeFor(&fix.subst, .{ .record_filter = &.{ "a", "b", "c" } });
    try testing.expectEqual(4, scheme.quantified);
}

test "an empty record filter is a filter yielding an empty record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(.{ .record_filter = &.{} }, "a -> [{}]");
}

test "record filter labels keep the order the desugarer normalized them into" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Position i in the argument list is label i in the record, which is what
    // pairs `record_filter[kind,name] p q` correctly. Unification matches
    // records by label, but the *scheme* must still pair them.
    try fix.expectScheme(
        .{ .record_filter = &.{ "alpha", "beta" } },
        "(a -> [b]) -> (a -> [c]) -> a -> [{alpha: b, beta: c}]",
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
        schemeFor(&fix.subst, .{ .record_filter = labels }),
    );
}

test "a record filter at the field ceiling still builds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, max_record_fields);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    const scheme = try schemeFor(&fix.subst, .{ .record_filter = labels });
    try testing.expectEqual(max_record_fields + 1, scheme.quantified);
}

test "a record filter scheme instantiates to fresh metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemeFor(&fix.subst, .{ .record_filter = &.{ "k", "n" } });
    const inst = try fix.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    try testing.expectEqualStrings(
        "(?0 -> [?1]) -> (?0 -> [?2]) -> ?0 -> [{k: ?1, n: ?2}]",
        buf.written(),
    );
}
