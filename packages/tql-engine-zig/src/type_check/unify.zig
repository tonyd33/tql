//! Structural unification with an occurs check.

const std = @import("std");
const core = @import("../core.zig");
const types = core.types;
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

    if (a != .meta and b == .meta) return bindMeta(subst, b.meta, a);

    switch (a) {
        .meta => |id| return bindMeta(subst, id, b),
        // A bound variable reaching unification means a scheme was used
        // without instantiation, which is a bug in the caller rather than a
        // type error in the program.
        .variable => @panic("a bound type variable reached unification"),
        .primitive => |p| {
            if (b != .primitive or b.primitive != p) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
        },
        // Nominal in the head, pointwise in the arguments.
        .constructor => |c| {
            if (b != .constructor or b.constructor.name != c.name or
                b.constructor.arguments.len != c.arguments.len)
            {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            for (c.arguments, b.constructor.arguments) |expected_arg, found_arg| {
                switch (unify(subst, expected_arg, found_arg)) {
                    .unified => {},
                    .mismatch => |m| return .{ .mismatch = m },
                }
            }
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
