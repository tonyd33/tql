//! Structural unification with an occurs check, and row unification for
//! records.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = core.datatypes;
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
    /// For `rigid` and `escape`, the rigid variable.
    skolem: ?*const types.Skolem = null,

    /// The same mismatch with its sides exchanged.
    pub fn swapped(self: Mismatch) Mismatch {
        var m = self;
        m.expected = self.found;
        m.found = self.expected;
        return m;
    }

    pub const Missing = struct {
        label: []const u8,
        /// The record without it.
        from: enum { expected, found },
    };

    pub const Reason = enum {
        /// Two different constructors.
        incompatible,
        /// Binding would have built an infinite type.
        occurs,
        /// Records whose label sets differ where no row can make up the
        /// difference.
        labels,
        /// A metavariable and a type of different kinds.
        kind,
        /// A rigid variable and a type other than itself.
        rigid,
        /// A metavariable and a type mentioning a rigid variable bound inside
        /// the metavariable's scope.
        escape,
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

    if (left == .meta) return try bindMeta(subst, left.meta, b);
    if (right == .meta) return switch (try bindMeta(subst, right.meta, a)) {
        .unified => .unified,
        .mismatch => |m| .{ .mismatch = m.swapped() },
    };

    if (left == .skolem or right == .skolem) {
        if (left == .skolem and right == .skolem and left.skolem == right.skolem) return .unified;
        const skolem = if (left == .skolem) left.skolem else right.skolem;
        return .{ .mismatch = .{ .reason = .rigid, .expected = a, .found = b, .skolem = skolem } };
    }

    // `m a` against `T x_1 .. x_n` is `m` against `T x_1 .. x_(n-1)` and `a`
    // against `x_n`.
    if (left == .application or right == .application) {
        const incompatible: Result = .{ .mismatch = .{ .reason = .incompatible, .expected = a, .found = b } };
        const l = try split(subst.arena, left) orelse return incompatible;
        const r = try split(subst.arena, right) orelse return incompatible;
        const l_kind = try kindOf(subst, subst.resolve(l.head));
        if (!l_kind.eql(try kindOf(subst, subst.resolve(r.head)))) {
            return .{ .mismatch = .{ .reason = .kind, .expected = a, .found = b } };
        }
        switch (try unify(subst, l.head, r.head)) {
            .unified => return try unify(subst, l.argument, r.argument),
            .mismatch => |m| return .{ .mismatch = m },
        }
    }

    switch (left) {
        .meta, .variable, .skolem => unreachable,
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
        .alias, .application => unreachable,
    }
    return .unified;
}

const Split = struct { head: types.Type, argument: types.Type };

/// `t` as a head at its last argument, when it is an application, a function
/// or a declared type at one or more arguments.
fn split(arena: Allocator, t: types.Type) Allocator.Error!?Split {
    switch (t) {
        .application => |a| return .{ .head = a.head, .argument = a.argument },
        .function => |arrow| return .{
            .head = try types.constructed(arena, datatypes.function_id, types.function_spelling, &.{arrow.from}),
            .argument = arrow.to,
        },
        .constructor => |c| {
            if (c.arguments.len == 0) return null;
            const last = c.arguments.len - 1;
            return .{
                .head = try types.constructed(arena, c.name, c.spelling, c.arguments[0..last]),
                .argument = c.arguments[last],
            };
        },
        else => return null,
    }
}

fn bindMeta(subst: *Substitution, id: types.Meta, t: types.Type) Allocator.Error!Result {
    const solution = try subst.occursCheck(id, t) orelse {
        return .{ .mismatch = .{ .reason = .occurs, .expected = .{ .meta = id }, .found = t } };
    };
    if (!try hasKind(subst, t, subst.kindOf(id))) {
        return .{ .mismatch = .{ .reason = .kind, .expected = .{ .meta = id }, .found = t } };
    }
    if (subst.promote(solution, subst.levelOf(id))) |skolem| {
        return .{ .mismatch = .{ .reason = .escape, .expected = .{ .meta = id }, .found = t, .skolem = skolem } };
    }
    subst.bind(id, solution);
    return .unified;
}

/// Whether `t` has kind `kind`. A record is a type or, after `|`, a row.
fn hasKind(subst: *Substitution, t: types.Type, kind: types.Kind) Allocator.Error!bool {
    const head = subst.expand(t);
    if (head == .record) return kind == .type or kind == .row;
    return (try kindOf(subst, head)).eql(kind);
}

/// The kind of `t`, which is neither a record nor a bound variable.
pub fn kindOf(subst: *Substitution, t: types.Type) Allocator.Error!types.Kind {
    return switch (t) {
        .meta => |id| subst.kindOf(id),
        .skolem => |k| k.kind,
        .constructor => |c| try types.Kind.arrows(subst.arena, subst.datatypes.get(c.name).parameters[c.arguments.len..], .type),
        .function => .type,
        .alias => |a| try kindOf(subst, a.expansion),
        .application => |a| (try kindOf(subst, subst.resolve(a.head))).arrow.to,
        .record, .variable => unreachable,
    };
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

    // Only a flexible row can hold the other side's extra labels, and one
    // row on both sides cannot hold labels only one side has.
    const same_row = left_row != .closed and std.meta.eql(left_row, right_row);
    if ((right_row != .flexible or same_row) and only_left.items.len > 0) {
        return missing(a, b, only_left.items[0].label, .found);
    }
    if ((left_row != .flexible or same_row) and only_right.items.len > 0) {
        return missing(a, b, only_right.items[0].label, .expected);
    }
    if (same_row) return .unified;

    const left_id = switch (left_row) {
        .flexible => |id| id,
        .closed, .rigid => switch (right_row) {
            .flexible => |id| return try bindMeta(subst, id, try withFields(subst, only_left.items, if (left.rest) |t| t.* else null)),
            .closed, .rigid => {
                const skolem = if (left_row == .rigid) left_row.rigid else if (right_row == .rigid) right_row.rigid else return .unified;
                return .{ .mismatch = .{ .reason = .rigid, .expected = a, .found = b, .skolem = skolem } };
            },
        },
    };
    const right_id = switch (right_row) {
        .flexible => |id| id,
        .closed, .rigid => return try bindMeta(subst, left_id, try withFields(subst, only_right.items, if (right.rest) |t| t.* else null)),
    };

    if (only_left.items.len == 0) {
        return try bindMeta(subst, left_id, try withFields(subst, only_right.items, .{ .meta = right_id }));
    }
    if (only_right.items.len == 0) {
        return try bindMeta(subst, right_id, try withFields(subst, only_left.items, .{ .meta = left_id }));
    }
    const shared = try subst.fresh(.row);
    switch (try bindMeta(subst, left_id, try withFields(subst, only_right.items, shared))) {
        .unified => {},
        .mismatch => |m| return .{ .mismatch = m },
    }
    return try bindMeta(subst, right_id, try withFields(subst, only_left.items, shared));
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

/// What a flattened record's `rest` is.
const Row = union(enum) {
    closed,
    flexible: types.Meta,
    rigid: *const types.Skolem,
};

fn row(rest: ?*const types.Type) Row {
    const t = rest orelse return .closed;
    return switch (t.*) {
        .meta => |id| .{ .flexible = id },
        .skolem => |k| .{ .rigid = k },
        else => unreachable,
    };
}

/// `{fields | rest}`, or `rest` itself when `fields` is empty. A null
/// `rest` closes the record.
fn withFields(subst: *Substitution, fields: []const types.Type.Field, rest: ?types.Type) Allocator.Error!types.Type {
    if (fields.len == 0) return rest orelse .{ .record = .{ .fields = &.{} } };
    return .{ .record = .{ .fields = fields, .rest = if (rest) |t| try types.store(subst.arena, t) else null } };
}
