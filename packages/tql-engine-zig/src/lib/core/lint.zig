//! Checks the invariants on join points.
//!
//! A binder whose details are `join(n)`:
//!
//! - occurs only as the head of an application of exactly `n` arguments, in
//!   tail position of the `let` or `letrec` that binds it;
//! - is bound to a value that opens with at least `n` lambdas;
//! - shares a `letrec` only with other join points.
//!
//! Tail positions are the body of a `let` or `letrec`, the alternatives and
//! default of a `case`, and a join point's value past its `n` lambdas. A
//! lambda body, an argument, a function position, the value of a `let` or
//! `letrec` that is not a join point, and a `case` scrutinee are not.

const std = @import("std");
const core = @import("../core.zig");
const symbols = @import("symbols.zig");

const Allocator = std.mem.Allocator;

pub const Violation = struct {
    binder: symbols.SymbolId,
    reason: Reason,

    pub const Reason = enum {
        /// Named outside the head of a tail call.
        not_tail_call,
        /// Applied to a number of arguments other than its arity.
        wrong_arity,
        /// Bound to a value with fewer lambdas than its arity.
        too_few_lambdas,
        /// In a `letrec` with a binder that is not a join point.
        mixed_group,
    };

    pub fn write(self: Violation, interner: *const symbols.Interner, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const what = switch (self.reason) {
            .not_tail_call => "is named outside the head of a tail call",
            .wrong_arity => "is applied to a number of arguments other than its arity",
            .too_few_lambdas => "is bound to a value with fewer lambdas than its arity",
            .mixed_group => "shares a letrec with a binder that is not a join point",
        };
        try w.print("join point `{s}` {s}", .{ interner.spelling(self.binder), what });
    }
};

/// Returns the first violation in `program`'s definitions, if any.
pub fn program(gpa: Allocator, p: *const core.Program) Allocator.Error!?Violation {
    for (p.definitions) |definition| {
        if (try term(gpa, &p.env.interner, definition.body)) |violation| return violation;
    }
    return null;
}

/// Returns the first violation in `t`, if any.
pub fn term(gpa: Allocator, interner: *const symbols.Interner, t: core.Term) Allocator.Error!?Violation {
    var linter: Linter = .{ .gpa = gpa, .interner = interner };
    defer linter.targets.deinit(gpa);
    linter.walk(t, null) catch |err| switch (err) {
        error.Violated => return linter.violation,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return null;
}

const Linter = struct {
    gpa: Allocator,
    interner: *const symbols.Interner,
    /// Join binders a jump may target, innermost last. A walk position sees
    /// those from its `from` index on.
    targets: std.ArrayList(symbols.SymbolId) = .empty,
    violation: Violation = undefined,

    const Error = Allocator.Error || error{Violated};

    fn arityOf(self: *const Linter, id: symbols.SymbolId) ?u32 {
        return self.interner.details(id).joinArity();
    }

    fn fail(self: *Linter, binder: symbols.SymbolId, reason: Violation.Reason) Error {
        self.violation = .{ .binder = binder, .reason = reason };
        return error.Violated;
    }

    fn targetable(self: *const Linter, id: symbols.SymbolId, from: ?usize) bool {
        const start = from orelse return false;
        return std.mem.indexOfScalar(symbols.SymbolId, self.targets.items[start..], id) != null;
    }

    /// Walk `t`, a tail position of the join binders in `targets[from..]`, or
    /// of none when `from` is null.
    fn walk(self: *Linter, t: core.Term, from: ?usize) Error!void {
        switch (t.kind) {
            .literal => {},
            .symbol, .apply => {
                const head = t.head();
                const arity = if (head.kind == .symbol) self.arityOf(head.kind.symbol) else null;
                var spine = t;
                while (spine.kind == .apply) : (spine = spine.kind.apply.function) {
                    try self.walk(spine.kind.apply.argument, null);
                }
                if (arity) |n| {
                    if (!self.targetable(head.kind.symbol, from)) return self.fail(head.kind.symbol, .not_tail_call);
                    if (n != t.spineLength()) return self.fail(head.kind.symbol, .wrong_arity);
                } else if (head.kind != .symbol) {
                    try self.walk(head, null);
                }
            },
            .lambda => |lambda| try self.walk(lambda.body, null),
            .case => |case_term| {
                try self.walk(case_term.scrutinee, null);
                for (case_term.alternatives) |alternative| try self.walk(alternative.body, from);
                if (case_term.default) |default| try self.walk(default, from);
            },
            .let => |let| {
                const arity = self.arityOf(let.name) orelse {
                    try self.walk(let.value, null);
                    return try self.walk(let.body, from);
                };
                try self.walkJoinValue(let.name, arity, let.value, from);
                const mark = self.targets.items.len;
                defer self.targets.shrinkRetainingCapacity(mark);
                try self.targets.append(self.gpa, let.name);
                try self.walk(let.body, from orelse mark);
            },
            .letrec => |letrec| {
                const joins = self.arityOf(letrec.bindings[0].name) != null;
                for (letrec.bindings) |binding| {
                    if ((self.arityOf(binding.name) != null) != joins) return self.fail(binding.name, .mixed_group);
                }
                if (!joins) {
                    for (letrec.bindings) |binding| try self.walk(binding.value, null);
                    return try self.walk(letrec.body, from);
                }
                const mark = self.targets.items.len;
                defer self.targets.shrinkRetainingCapacity(mark);
                for (letrec.bindings) |binding| try self.targets.append(self.gpa, binding.name);
                const inner = from orelse mark;
                for (letrec.bindings) |binding| {
                    try self.walkJoinValue(binding.name, self.arityOf(binding.name).?, binding.value, inner);
                }
                try self.walk(letrec.body, inner);
            },
        }
    }

    /// Walk a join point's value: its first `arity` lambdas, then the rest as
    /// a tail position of `from`.
    fn walkJoinValue(self: *Linter, binder: symbols.SymbolId, arity: u32, value: core.Term, from: ?usize) Error!void {
        if (value.arity() < arity) return self.fail(binder, .too_few_lambdas);
        try self.walk(value.underLambdas(arity), from);
    }
};

const test_support = @import("test_support.zig");

fn expectViolation(pb: *test_support.ProgramBuilder, expected: ?Violation, t: core.Term) !void {
    try std.testing.expectEqual(expected, try term(std.testing.allocator, &pb.env.interner, t));
}

test "a join point called in every alternative is accepted" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    try pb.datatype("B", &.{ .{ "F", &.{} }, .{ "T", &.{} } });
    const f = try pb.global("F");
    const tr = try pb.global("T");
    const g = try pb.global("g");
    const b = try pb.local("b");
    const x = try pb.local("x");
    const j = try pb.join("j", 1);
    const t = try pb.lambda(&.{b}, try pb.let(
        j,
        try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{pb.symbol(x)})),
        try pb.case(pb.symbol(b), &.{
            .{ .constructor = f, .binders = &.{}, .body = try pb.apply(pb.symbol(j), &.{pb.number(1)}) },
            .{ .constructor = tr, .binders = &.{}, .body = try pb.apply(pb.symbol(j), &.{pb.number(2)}) },
        }),
    ));
    try expectViolation(&pb, null, t);
}

test "a jump from a scrutinee is not a tail call" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    try pb.datatype("B", &.{ .{ "F", &.{} }, .{ "T", &.{} } });
    const f = try pb.global("F");
    const tr = try pb.global("T");
    const j = try pb.join("j", 0);
    const t = try pb.let(j, pb.number(1), try pb.case(pb.symbol(j), &.{
        .{ .constructor = f, .binders = &.{}, .body = pb.number(2) },
        .{ .constructor = tr, .binders = &.{}, .body = pb.number(3) },
    }));
    try expectViolation(&pb, .{ .binder = j, .reason = .not_tail_call }, t);
}

test "a jump under a lambda is not a tail call" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const x = try pb.local("x");
    const j = try pb.join("j", 0);
    const t = try pb.let(j, pb.number(1), try pb.lambda(&.{x}, pb.symbol(j)));
    try expectViolation(&pb, .{ .binder = j, .reason = .not_tail_call }, t);
}

test "a jump as an argument is not a tail call" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const g = try pb.global("g");
    const j = try pb.join("j", 0);
    const t = try pb.let(j, pb.number(1), try pb.apply(pb.symbol(g), &.{pb.symbol(j)}));
    try expectViolation(&pb, .{ .binder = j, .reason = .not_tail_call }, t);
}

test "a jump from an ordinary let's value is not a tail call" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const y = try pb.local("y");
    const j = try pb.join("j", 0);
    const t = try pb.let(j, pb.number(1), try pb.let(y, pb.symbol(j), pb.symbol(y)));
    try expectViolation(&pb, .{ .binder = j, .reason = .not_tail_call }, t);
}

test "a jump with too few arguments is the wrong arity" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const x = try pb.local("x");
    const y = try pb.local("y");
    const j = try pb.join("j", 2);
    const t = try pb.let(j, try pb.lambda(&.{ x, y }, pb.symbol(x)), try pb.apply(pb.symbol(j), &.{pb.number(1)}));
    try expectViolation(&pb, .{ .binder = j, .reason = .wrong_arity }, t);
}

test "a join point's value needs its arity in lambdas" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const j = try pb.join("j", 1);
    const t = try pb.let(j, pb.number(1), try pb.apply(pb.symbol(j), &.{pb.number(2)}));
    try expectViolation(&pb, .{ .binder = j, .reason = .too_few_lambdas }, t);
}

test "a join point's value is a tail position of the enclosing join points" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const outer = try pb.join("outer", 0);
    const inner = try pb.join("inner", 0);
    const t = try pb.let(outer, pb.number(1), try pb.let(inner, pb.symbol(outer), pb.symbol(inner)));
    try expectViolation(&pb, null, t);
}

test "a join point is not a target of its own value" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const j = try pb.join("j", 0);
    const t = try pb.let(j, pb.symbol(j), pb.symbol(j));
    try expectViolation(&pb, .{ .binder = j, .reason = .not_tail_call }, t);
}

test "a recursive join point jumps to itself" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const x = try pb.local("x");
    const j = try pb.join("j", 1);
    const t = try pb.letrec(&.{
        .{ .name = j, .value = try pb.lambda(&.{x}, try pb.apply(pb.symbol(j), &.{pb.symbol(x)})) },
    }, try pb.apply(pb.symbol(j), &.{pb.number(1)}));
    try expectViolation(&pb, null, t);
}

test "a letrec mixing a join point and a function is rejected" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.local("f");
    const j = try pb.join("j", 0);
    const t = try pb.letrec(&.{
        .{ .name = j, .value = pb.number(1) },
        .{ .name = f, .value = pb.number(2) },
    }, pb.symbol(j));
    try expectViolation(&pb, .{ .binder = f, .reason = .mixed_group }, t);
}
