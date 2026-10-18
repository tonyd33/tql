//! Structural unification with an occurs check, and unification of rows
//! up to label order.

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
    /// For `labels`, a label one row has and the other cannot.
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
        /// The row without it.
        from: enum { expected, found },
    };

    pub const Reason = enum {
        /// Two different constructors.
        incompatible,
        /// Binding would have built an infinite type.
        occurs,
        /// Rows whose label sets differ where no tail can make up the
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
    return try unifyNamed(subst, expected, found, null);
}

/// The types a mismatch names.
const Pair = struct { expected: types.Type, found: types.Type };

/// `unify`, naming `named` in a mismatch between `expected` and `found`
/// themselves. A row is written only inside a record, so a mismatch at a row
/// names the records.
fn unifyNamed(
    subst: *Substitution,
    expected: types.Type,
    found: types.Type,
    named: ?Pair,
) Allocator.Error!Result {
    // `a` and `b` are as written, and are what a metavariable is bound to.
    // `left` and `right` are their expansions, and are what is compared.
    const a = subst.resolve(expected);
    const b = subst.resolve(found);
    const left = subst.expand(a);
    const right = subst.expand(b);
    const shown = named orelse Pair{ .expected = a, .found = b };

    if (left == .meta and right == .meta and left.meta == right.meta) return .unified;

    if (left == .meta) return naming(try bindMeta(subst, left.meta, b), named);
    if (right == .meta) return naming(switch (try bindMeta(subst, right.meta, a)) {
        .unified => .unified,
        .mismatch => |m| .{ .mismatch = m.swapped() },
    }, named);

    if (left == .skolem or right == .skolem) {
        if (left == .skolem and right == .skolem and left.skolem == right.skolem) return .unified;
        const skolem = if (left == .skolem) left.skolem else right.skolem;
        return .{ .mismatch = .{ .reason = .rigid, .expected = shown.expected, .found = shown.found, .skolem = skolem } };
    }

    const incompatible: Result = .{ .mismatch = .{ .reason = .incompatible, .expected = shown.expected, .found = shown.found } };

    // `m a` against `T x_1 .. x_n` is `m` against `T x_1 .. x_(n-1)` and `a`
    // against `x_n`.
    if (left == .application or right == .application) {
        const l = try split(subst.arena, left) orelse return incompatible;
        const r = try split(subst.arena, right) orelse return incompatible;
        const l_kind = try kindOf(subst, subst.resolve(l.head));
        if (!l_kind.eql(try kindOf(subst, subst.resolve(r.head)))) {
            return .{ .mismatch = .{ .reason = .kind, .expected = shown.expected, .found = shown.found } };
        }
        switch (try unify(subst, l.head, r.head)) {
            .unified => return try unifyNamed(subst, l.argument, r.argument, rowOf(l_kind.arrow.from, shown)),
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
                return incompatible;
            }
            const parameters = subst.datatypes.get(c.name).parameters;
            for (c.arguments, right.constructor.arguments, parameters[0..c.arguments.len]) |expected_arg, found_arg, kind| {
                switch (try unifyNamed(subst, expected_arg, found_arg, rowOf(kind, shown))) {
                    .unified => {},
                    .mismatch => |m| return .{ .mismatch = m },
                }
            }
        },
        .function => |arrow| {
            if (right != .function) return incompatible;
            switch (try unify(subst, arrow.from, right.function.from)) {
                .unified => return try unify(subst, arrow.to, right.function.to),
                .mismatch => |m| return .{ .mismatch = m },
            }
        },
        .row => |r| return try rows(subst, shown, r, right.row),
        .alias, .application => unreachable,
    }
    return .unified;
}

/// `shown`, when an argument of kind `kind` is a row.
fn rowOf(kind: types.Kind, shown: Pair) ?Pair {
    return if (kind == .row) shown else null;
}

/// `result` with `named` in place of its mismatch's types.
fn naming(result: Result, named: ?Pair) Result {
    const pair = named orelse return result;
    return switch (result) {
        .unified => .unified,
        .mismatch => |m| blk: {
            var renamed = m;
            renamed.expected = pair.expected;
            renamed.found = pair.found;
            break :blk .{ .mismatch = renamed };
        },
    };
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
    if (!(try kindOf(subst, subst.expand(t))).eql(subst.kindOf(id))) {
        return .{ .mismatch = .{ .reason = .kind, .expected = .{ .meta = id }, .found = t } };
    }
    if (subst.promote(solution, subst.levelOf(id))) |skolem| {
        return .{ .mismatch = .{ .reason = .escape, .expected = .{ .meta = id }, .found = t, .skolem = skolem } };
    }
    subst.bind(id, solution);
    return .unified;
}

/// The kind of `t`, which is not a bound variable.
pub fn kindOf(subst: *Substitution, t: types.Type) Allocator.Error!types.Kind {
    return switch (t) {
        .meta => |id| subst.kindOf(id),
        .skolem => |k| k.kind,
        .constructor => |c| try types.Kind.arrows(subst.arena, subst.datatypes.get(c.name).parameters[c.arguments.len..], .type),
        .function => .type,
        .row => .row,
        .alias => |a| try kindOf(subst, a.expansion),
        .application => |a| (try kindOf(subst, subst.resolve(a.head))).arrow.to,
        .variable => unreachable,
    };
}

/// Unifies two rows label by label, then solves their tails for the labels
/// only one side has. A mismatch between the rows names `shown`.
fn rows(
    subst: *Substitution,
    shown: Pair,
    expected: types.Type.Row,
    found: types.Type.Row,
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

    const left_tail = tailOf(left.tail);
    const right_tail = tailOf(right.tail);

    // Only a flexible tail can hold the other side's extra labels, and one
    // tail on both sides cannot hold labels only one side has.
    const same_tail = left_tail != .closed and std.meta.eql(left_tail, right_tail);
    if ((right_tail != .flexible or same_tail) and only_left.items.len > 0) {
        return missing(shown, only_left.items[0].label, .found);
    }
    if ((left_tail != .flexible or same_tail) and only_right.items.len > 0) {
        return missing(shown, only_right.items[0].label, .expected);
    }
    if (same_tail) return .unified;

    const left_id = switch (left_tail) {
        .flexible => |id| id,
        .closed, .rigid => switch (right_tail) {
            .flexible => |id| return try bindTail(subst, shown, id, try withFields(subst, only_left.items, if (left.tail) |t| t.* else null)),
            .closed, .rigid => {
                const skolem = if (left_tail == .rigid) left_tail.rigid else if (right_tail == .rigid) right_tail.rigid else return .unified;
                return .{ .mismatch = .{ .reason = .rigid, .expected = shown.expected, .found = shown.found, .skolem = skolem } };
            },
        },
    };
    const right_id = switch (right_tail) {
        .flexible => |id| id,
        .closed, .rigid => return try bindTail(subst, shown, left_id, try withFields(subst, only_right.items, if (right.tail) |t| t.* else null)),
    };

    if (only_left.items.len == 0) {
        return try bindTail(subst, shown, left_id, try withFields(subst, only_right.items, .{ .meta = right_id }));
    }
    if (only_right.items.len == 0) {
        return try bindTail(subst, shown, right_id, try withFields(subst, only_left.items, .{ .meta = left_id }));
    }
    const shared = try subst.fresh(.row);
    switch (try bindTail(subst, shown, left_id, try withFields(subst, only_right.items, shared))) {
        .unified => {},
        .mismatch => |m| return .{ .mismatch = m },
    }
    return try bindTail(subst, shown, right_id, try withFields(subst, only_left.items, shared));
}

/// `bindMeta` for a row's tail, naming `shown` in a mismatch.
fn bindTail(subst: *Substitution, shown: Pair, id: types.Meta, t: types.Type) Allocator.Error!Result {
    return naming(try bindMeta(subst, id, t), shown);
}

fn missing(
    shown: Pair,
    label: []const u8,
    from: @FieldType(Mismatch.Missing, "from"),
) Result {
    return .{ .mismatch = .{
        .reason = .labels,
        .expected = shown.expected,
        .found = shown.found,
        .missing = .{ .label = label, .from = from },
    } };
}

/// What a flattened row's `tail` is.
const Tail = union(enum) {
    closed,
    flexible: types.Meta,
    rigid: *const types.Skolem,
};

fn tailOf(tail: ?*const types.Type) Tail {
    const t = tail orelse return .closed;
    return switch (t.*) {
        .meta => |id| .{ .flexible = id },
        .skolem => |k| .{ .rigid = k },
        else => unreachable,
    };
}

/// `(fields | tail)`, or `tail` itself when `fields` is empty. A null
/// `tail` closes the row.
fn withFields(subst: *Substitution, fields: []const types.Type.Field, tail: ?types.Type) Allocator.Error!types.Type {
    if (fields.len == 0) return tail orelse .{ .row = .{ .fields = &.{} } };
    return .{ .row = .{ .fields = fields, .tail = if (tail) |t| try types.store(subst.arena, t) else null } };
}
