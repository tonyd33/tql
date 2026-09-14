//! Runtime values and the thunks that produce them.
//!
//! Every heap cell is a Thunk. Forcing one runs it at most once and memoizes
//! the result. Globals, letrec bindings and constructor fields are all thunks.
//!
//! Entering an `evaluating` thunk is a divergence the language specifies. The
//! black hole reports it instead of hanging.
//!
//! Nothing is collected during a run: thunks live in one arena freed when the
//! run ends, so a query producing a long lazy list peaks at the whole list.
//! Collecting mid-run needs refcounting or tracing, since thunks are mutable
//! and mutually referential.

const std = @import("std");
const core = @import("../lang/core.zig");
const stg = @import("stg.zig");
const symbols = @import("../lang/symbols.zig");

const Allocator = std.mem.Allocator;

pub const Point = struct {
    row: u32,
    column: u32,
};

pub const Range = struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

/// A node in the queried tree. Opaque until the tree primitives exist; the
/// machine never reads one.
pub const Node = struct {
    id: u32,
};

/// A name bound to a thunk. An environment is a slice of these.
pub const Binding = struct {
    name: symbols.SymbolId,
    thunk: *Thunk,
};

/// An allocated closure: its code, and what its free variables were bound to
/// when it was allocated.
pub const Closure = struct {
    code: *const stg.Closure,
    captured: []const Binding,
    /// Arguments already supplied by a partial application, in order.
    applied: []const *Thunk = &.{},
};

pub const Constructed = struct {
    constructor: symbols.SymbolId,
    tag: u32,
    fields: []const *Thunk,
};

/// A record field. Labels arrive sorted from the desugarer and stay that way,
/// so two records of the same type compare field by field.
pub const Field = struct {
    label: []const u8,
    thunk: *Thunk,
};

pub const Value = union(enum) {
    constructed: Constructed,
    record: []const Field,
    closure: Closure,
    number: i64,
    string: []const u8,
    regex: []const u8,
    node: Node,
    range: Range,
};

pub const State = union(enum) {
    unevaluated: Pending,
    /// Entered and not yet finished. Re-entering is a cycle.
    evaluating,
    evaluated: Value,

    pub const Pending = struct {
        code: *const stg.Closure,
        captured: []const Binding,
    };
};

pub const Thunk = struct {
    state: State,

    pub fn value(v: Value) Thunk {
        return .{ .state = .{ .evaluated = v } };
    }

    /// Mark the thunk entered. Callers write the result back with `fill`, or
    /// report a cycle if this returns false.
    pub fn enter(self: *Thunk) bool {
        switch (self.state) {
            .evaluating => return false,
            else => {
                self.state = .evaluating;
                return true;
            },
        }
    }

    /// Overwrite an entered thunk with its result. Drops the reference to its
    /// captured environment, so a forced cell stops keeping its inputs
    /// reachable.
    pub fn fill(self: *Thunk, v: Value) void {
        self.state = .{ .evaluated = v };
    }
};

test "a fresh thunk is unevaluated and enters once" {
    var t: Thunk = .{ .state = .{ .unevaluated = .{ .code = undefined, .captured = &.{} } } };
    try std.testing.expect(t.enter());
    try std.testing.expectEqual(State.evaluating, t.state);
}

test "re-entering an evaluating thunk is refused" {
    var t: Thunk = .{ .state = .evaluating };
    try std.testing.expect(!t.enter());
}

test "filling memoizes the result" {
    var t: Thunk = .{ .state = .{ .unevaluated = .{ .code = undefined, .captured = &.{} } } };
    _ = t.enter();
    t.fill(.{ .number = 7 });
    try std.testing.expectEqual(@as(i64, 7), t.state.evaluated.number);
    try std.testing.expect(t.enter());
}

test "a thunk is entered once and read thereafter" {
    // An evaluator that re-evaluates returns the same answers, so counting
    // entries is the only thing that catches a missing memoization.
    var t: Thunk = .{ .state = .{ .unevaluated = .{ .code = undefined, .captured = &.{} } } };

    var entries: u32 = 0;
    if (t.enter()) {
        entries += 1;
        t.fill(.{ .number = 1 });
    }
    // A forced thunk is `evaluated`, so a second force reads it rather than
    // entering. `enter` would succeed here, which is why `force` checks the
    // state before calling it.
    try std.testing.expect(t.state == .evaluated);
    try std.testing.expectEqual(1, entries);
    try std.testing.expectEqual(@as(i64, 1), t.state.evaluated.number);
}

test "an evaluated thunk holds its value" {
    const t = Thunk.value(.{ .string = "ab" });
    try std.testing.expectEqualStrings("ab", t.state.evaluated.string);
}
