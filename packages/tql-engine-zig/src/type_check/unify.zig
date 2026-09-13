//! Structural unification with an occurs check.

const std = @import("std");
const types = @import("../lang/types.zig");
const Substitution = @import("substitution.zig").Substitution;

const Allocator = std.mem.Allocator;

/// Why two types could not be made equal. The pair that actually conflicted is
/// carried, which is not always the pair unification was called with: for
/// `[int]` against `[string]` the mismatch to report is `int` against `string`.
pub const Mismatch = struct {
    reason: Reason,
    expected: types.Type,
    found: types.Type,

    pub const Reason = enum {
        /// Two different constructors, or two different primitives.
        incompatible,
        /// Binding would have built an infinite type.
        occurs,
        /// Records whose label sets differ.
        labels,
    };
};

/// Whether the two types could be made equal.
pub const Result = union(enum) {
    unified,
    mismatch: Mismatch,
};

/// Makes `expected` and `found` equal, recording the solution in `subst`.
pub fn unify(
    subst: *Substitution,
    expected: types.Type,
    found: types.Type,
) Result {
    const a = subst.resolve(expected);
    const b = subst.resolve(found);

    if (a == .meta and b == .meta and a.meta == b.meta) return .unified;

    if (a == .meta) return bindMeta(subst, a.meta, b);
    if (b == .meta) return bindMeta(subst, b.meta, a);

    switch (a) {
        .meta => unreachable,
        // A bound variable reaching unification means a scheme was used
        // without instantiation, which is a bug in the caller rather than a
        // type error in the program.
        .variable => unreachable,
        .primitive => |p| {
            if (b != .primitive or b.primitive != p) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
        },
        .list => |element| {
            if (b != .list) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            return unify(subst, element.*, b.list.*);
        },
        .function => |arrow| {
            if (b != .function) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            switch (unify(subst, arrow.from, b.function.from)) {
                .unified => return unify(subst, arrow.to, b.function.to),
                .mismatch => |m| return .{ .mismatch = m },
            }
        },
        .record => |fields| {
            if (b != .record) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            const others = b.record;
            if (fields.len != others.len) {
                return .{ .mismatch = .{ .reason = .labels, .expected = a, .found = b } };
            }
            // Records are closed and order-insensitive, so the label sets must
            // match exactly. There is no row variable, so a missing label is a
            // mismatch rather than something to solve for.
            for (fields) |f| {
                const match = findLabel(others, f.label) orelse
                    return .{ .mismatch = .{ .reason = .labels, .expected = a, .found = b } };
                switch (unify(subst, f.type.*, match.type.*)) {
                    .unified => {},
                    .mismatch => |m| return .{ .mismatch = m },
                }
            }
        },
    }
    return .unified;
}

fn bindMeta(subst: *Substitution, id: types.Meta, t: types.Type) Result {
    if (subst.occurs(id, t)) {
        return .{ .mismatch = .{ .reason = .occurs, .expected = .{ .meta = id }, .found = t } };
    }
    subst.bind(id, t);
    return .unified;
}

fn findLabel(fields: []const types.Type.Field, label: []const u8) ?types.Type.Field {
    for (fields) |f| {
        if (std.mem.eql(u8, f.label, label)) return f;
    }
    return null;
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    subst: Substitution,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .arena = .init(gpa), .subst = undefined };
        self.subst = Substitution.init(gpa, self.arena.allocator());
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.subst.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Unifies, failing the test if the two types mismatch instead.
    fn expectUnifies(self: *Fixture, expected: types.Type, found: types.Type) !void {
        return switch (unify(&self.subst, expected, found)) {
            .unified => {},
            .mismatch => error.TestUnexpectedResult,
        };
    }

    /// The mismatch `expected` and `found` produce, failing the test if they
    /// unify instead.
    fn mismatch(self: *Fixture, expected: types.Type, found: types.Type) !Mismatch {
        return switch (unify(&self.subst, expected, found)) {
            .unified => error.TestUnexpectedResult,
            .mismatch => |m| m,
        };
    }

    fn record(self: *Fixture, labels: []const []const u8, field_types: []const types.Type) !types.Type {
        const fields = try self.arena.allocator().alloc(types.Type.Field, labels.len);
        for (labels, field_types, fields) |label, t, *f| {
            f.* = .{ .label = label, .type = try types.store(self.subst.arena, t) };
        }
        return .{ .record = fields };
    }

    fn expectRenders(self: *Fixture, t: types.Type, expected: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try (try self.subst.resolveDeep(t)).format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }
};

test "identical primitives unify" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectUnifies(types.int_type, types.int_type);
}

test "different primitives do not" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(types.int_type, types.string_type);
    try testing.expectEqual(Mismatch.Reason.incompatible, m.reason);
}

test "an unsolved metavariable takes the other side" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, types.node_type);
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
}

test "binding is symmetric" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(types.node_type, a);
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
}

test "a metavariable unified with itself is a no-op" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, a);
    try testing.expectEqual(null, fix.subst.lookup(a.meta));
}

test "two metavariables become one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(a, b);
    try fix.expectUnifies(b, types.string_type);

    // Solving either solves both.
    try testing.expectEqual(types.string_type, fix.subst.resolve(a));
}

test "lists unify elementwise" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(try types.list(fix.subst.arena, a), try types.list(fix.subst.arena, types.int_type));
    try testing.expectEqual(types.int_type, fix.subst.resolve(a));
}

test "a list does not unify with its element type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    _ = try fix.mismatch(try types.list(fix.subst.arena, types.int_type), types.int_type);
}

test "the reported mismatch is the pair that conflicted, not the outer one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(
        try types.list(fix.subst.arena, types.int_type),
        try types.list(fix.subst.arena, types.string_type),
    );
    // `[int]` vs `[string]` would make a reader hunt for the difference.
    try testing.expectEqual(types.int_type, m.expected);
    try testing.expectEqual(types.string_type, m.found);
}

test "arrows unify on both sides" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(
        try types.func(fix.subst.arena, a, b),
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
    try testing.expectEqual(types.string_type, fix.subst.resolve(b));
}

test "a filter is an arrow to a list, and unifies as one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(
        try types.filter(fix.subst.arena, a, b),
        comptime types.filter_type(types.node_type, types.string_type),
    );
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
    try testing.expectEqual(types.string_type, fix.subst.resolve(b));
}

test "a projection does not unify with a filter" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `kind : Node -> String`, and `main` needs `Filter Node output`. This is
    // what rejects `main = kind`.
    const a = try fix.subst.fresh();
    _ = try fix.mismatch(
        comptime types.func_type(types.node_type, types.string_type),
        try types.filter(fix.subst.arena, types.node_type, a),
    );
}

test "records unify regardless of label order" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, a }),
        try fix.record(&.{ "n", "k" }, &.{ types.int_type, types.string_type }),
    );
    try testing.expectEqual(types.int_type, fix.subst.resolve(a));
}

test "records with different label sets do not unify" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(
        try fix.record(&.{"k"}, &.{types.string_type}),
        try fix.record(&.{"other"}, &.{types.string_type}),
    );
    try testing.expectEqual(Mismatch.Reason.labels, m.reason);
}

test "a wider record does not unify with a narrower one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // No width subtyping: `{k, n}` is not acceptable where `{k}` is wanted.
    const m = try fix.mismatch(
        try fix.record(&.{"k"}, &.{types.string_type}),
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, types.int_type }),
    );
    try testing.expectEqual(Mismatch.Reason.labels, m.reason);
}

test "record fields unify by label, not by position" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Same labels in swapped order with mismatched types: if the unifier
    // paired positionally, this would wrongly succeed.
    _ = try fix.mismatch(
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, types.int_type }),
        try fix.record(&.{ "n", "k" }, &.{ types.string_type, types.int_type }),
    );
}

test "the occurs check rejects an infinite type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const m = try fix.mismatch(a, try types.list(fix.subst.arena, a));
    try testing.expectEqual(Mismatch.Reason.occurs, m.reason);
}

test "the occurs check sees through solved metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(b, try types.list(fix.subst.arena, a));
    // `a := b` is now `a := [a]`, reachable only by resolving `b`.
    const m = try fix.mismatch(a, b);
    try testing.expectEqual(Mismatch.Reason.occurs, m.reason);
}

test "unification is transitive through nested structure" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    const c = try fix.subst.fresh();

    // `a := [b]` from the argument, then `b := c` and `c := int` chain through
    // to make the argument `[int]`.
    try fix.expectUnifies(a, try types.list(fix.subst.arena, b));
    try fix.expectUnifies(b, c);
    try fix.expectUnifies(c, types.int_type);

    try fix.expectRenders(a, "[Int]");
}

test "an arrow whose two sides force one metavariable transitively" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();

    // `(a -> b)` against `(b -> node)` forces `a := b` then `b := node`.
    try fix.expectUnifies(try types.func(fix.subst.arena, a, b), try types.func(fix.subst.arena, b, types.node_type));
    try fix.expectRenders(a, "Node");
    try fix.expectRenders(b, "Node");
}

test "a self-referential arrow is rejected as an infinite type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();

    // `(a -> [b])` against `(b -> a)`: the argument gives `a := b`, and then
    // the result asks for `b := [b]`.
    const m = try fix.mismatch(
        try types.func(fix.subst.arena, a, try types.list(fix.subst.arena, b)),
        try types.func(fix.subst.arena, b, a),
    );
    try testing.expectEqual(Mismatch.Reason.occurs, m.reason);
}

test "a solved metavariable unifies against what it was solved to" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, types.int_type);
    try fix.expectUnifies(a, types.int_type);
    _ = try fix.mismatch(a, types.string_type);
}
