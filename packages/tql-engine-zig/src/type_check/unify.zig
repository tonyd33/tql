//! Structural unification with an occurs check, and row unification for
//! records.

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
    /// For `labels`, a label one record has and the other cannot.
    missing: ?Missing = null,

    pub const Missing = struct {
        label: []const u8,
        /// The record without it.
        from: enum { expected, found },
    };

    pub const Reason = enum {
        /// Two different constructors, or two different primitives.
        incompatible,
        /// Binding would have built an infinite type.
        occurs,
        /// Records whose label sets differ where no row can make up the
        /// difference.
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
) Allocator.Error!Result {
    // `a` and `b` are as written, and are what a metavariable is bound to
    // and a mismatch names. `left` and `right` are their expansions, and are
    // what is compared.
    const a = subst.resolve(expected);
    const b = subst.resolve(found);
    const left = subst.expand(a);
    const right = subst.expand(b);

    if (left == .meta and right == .meta and left.meta == right.meta) return .unified;

    if (left != .meta and right == .meta) return bindMeta(subst, right.meta, a);

    switch (left) {
        .meta => |id| return bindMeta(subst, id, b),
        // A bound variable reaching unification means a scheme was used
        // without instantiation, which is a bug in the caller rather than a
        // type error in the program.
        .variable => @panic("a bound type variable reached unification"),
        .primitive => |p| {
            if (right != .primitive or right.primitive != p) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
        },
        // Nominal in the head, pointwise in the arguments.
        .constructor => |c| {
            if (right != .constructor or right.constructor.name != c.name or
                right.constructor.arguments.len != c.arguments.len)
            {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            for (c.arguments, right.constructor.arguments) |expected_arg, found_arg| {
                switch (try unify(subst, expected_arg, found_arg)) {
                    .unified => {},
                    .mismatch => |m| return .{ .mismatch = m },
                }
            }
        },
        .function => |arrow| {
            if (right != .function) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            switch (try unify(subst, arrow.from, right.function.from)) {
                .unified => return try unify(subst, arrow.to, right.function.to),
                .mismatch => |m| return .{ .mismatch = m },
            }
        },
        .record => |r| {
            if (right != .record) {
                return .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
            }
            return try records(subst, a, b, r, right.record);
        },
        .alias => unreachable,
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

/// Unifies two records label by label, then solves their rows for the labels
/// only one side has. `a` and `b` are the records as written, for a mismatch
/// to name.
fn records(
    subst: *Substitution,
    a: types.Type,
    b: types.Type,
    expected: types.Type.Record,
    found: types.Type.Record,
) Allocator.Error!Result {
    const left = try subst.flatten(expected);
    const right = try subst.flatten(found);

    var only_left: std.ArrayList(types.Type.Field) = .empty;
    var only_right: std.ArrayList(types.Type.Field) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.fields.len and j < right.fields.len) {
        const l = left.fields[i];
        const r = right.fields[j];
        switch (types.Type.Field.order(l.label, r.label)) {
            .eq => {
                switch (try unify(subst, l.type.*, r.type.*)) {
                    .unified => {},
                    .mismatch => |m| return .{ .mismatch = m },
                }
                i += 1;
                j += 1;
            },
            .lt => {
                try only_left.append(subst.arena, l);
                i += 1;
            },
            .gt => {
                try only_right.append(subst.arena, r);
                j += 1;
            },
        }
    }
    try only_left.appendSlice(subst.arena, left.fields[i..]);
    try only_right.appendSlice(subst.arena, right.fields[j..]);

    const left_row = row(left.rest);
    const right_row = row(right.rest);

    // A closed side has no row to hold the other side's extra labels, and one
    // row on both sides cannot hold labels only one side has.
    const same_row = left_row != null and left_row == right_row;
    if ((right_row == null or same_row) and only_left.items.len > 0) {
        return missing(a, b, only_left.items[0].label, .found);
    }
    if ((left_row == null or same_row) and only_right.items.len > 0) {
        return missing(a, b, only_right.items[0].label, .expected);
    }
    if (same_row) return .unified;

    const left_id = left_row orelse {
        const right_id = right_row orelse return .unified;
        return bindMeta(subst, right_id, .{ .record = .{ .fields = only_left.items } });
    };
    const right_id = right_row orelse {
        return bindMeta(subst, left_id, .{ .record = .{ .fields = only_right.items } });
    };

    if (only_left.items.len == 0) {
        return bindMeta(subst, left_id, try withFields(subst, only_right.items, .{ .meta = right_id }));
    }
    if (only_right.items.len == 0) {
        return bindMeta(subst, right_id, try withFields(subst, only_left.items, .{ .meta = left_id }));
    }
    const shared = try subst.fresh();
    switch (bindMeta(subst, left_id, try withFields(subst, only_right.items, shared))) {
        .unified => {},
        .mismatch => |m| return .{ .mismatch = m },
    }
    return bindMeta(subst, right_id, try withFields(subst, only_left.items, shared));
}

fn missing(
    expected: types.Type,
    found: types.Type,
    label: []const u8,
    from: @FieldType(Mismatch.Missing, "from"),
) Result {
    return .{ .mismatch = .{
        .reason = .labels,
        .expected = expected,
        .found = found,
        .missing = .{ .label = label, .from = from },
    } };
}

/// The metavariable a flattened record's `rest` is, or null for a closed
/// record.
fn row(rest: ?*const types.Type) ?types.Meta {
    const t = rest orelse return null;
    return switch (t.*) {
        .meta => |id| id,
        .variable => @panic("a bound type variable reached unification"),
        else => unreachable,
    };
}

/// `{fields | rest}`, or `rest` itself when `fields` is empty.
fn withFields(subst: *Substitution, fields: []const types.Type.Field, rest: types.Type) Allocator.Error!types.Type {
    if (fields.len == 0) return rest;
    return .{ .record = .{ .fields = fields, .rest = try types.store(subst.arena, rest) } };
}
