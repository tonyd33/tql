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
const ts = @import("tree-sitter");
const core = @import("../core.zig");
const stg = @import("terms.zig");

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

/// A node in the queried tree.
///
/// Holds the tree-sitter node by value. The tree it points into must outlive
/// every value the query produces, including thunks forced during
/// serialization.
pub const Node = struct {
    inner: ts.Node,
};

/// An allocated closure: its code, and what its free variables were bound to
/// when it was allocated.
pub const Closure = struct {
    code: *const stg.Closure,
    /// What the lambda-form's free variables were bound to, in its order, so
    /// the body reads them at offsets 0..free.len of its environment.
    captured: []const *Thunk,
    /// Arguments already supplied by a partial application, in order.
    applied: []const *Thunk = &.{},
};

pub const Constructed = struct {
    constructor: core.SymbolId,
    tag: u32,
    /// Field count, whether they are inline or spilled.
    len: u32,
    storage: Storage,

    /// Up to two fields live in the value itself. `Cons` has exactly two and
    /// is almost every cell a query builds, so inlining them removes one
    /// allocation per list cell.
    pub const inline_capacity = 2;

    /// Untagged: `len` says which arm is live. Both arms are the same size,
    /// so the value is no larger than the inline case it exists for.
    pub const Storage = extern union {
        inline_fields: [inline_capacity]*Thunk,
        spilled: extern struct { ptr: [*]const *Thunk, _pad: usize = 0 },
    };

    pub fn fields(self: *const Constructed) []const *Thunk {
        if (self.len <= inline_capacity) return self.storage.inline_fields[0..self.len];
        return self.storage.spilled.ptr[0..self.len];
    }

    /// Build from fields the caller already has laid out contiguously.
    ///
    /// `spill` must outlive the value when there are more than
    /// `inline_capacity` of them; at or below it the fields are copied and
    /// `spill` is not retained.
    pub fn init(constructor: core.SymbolId, tag: u32, spill: []const *Thunk) Constructed {
        var self: Constructed = .{
            .constructor = constructor,
            .tag = tag,
            .len = @intCast(spill.len),
            .storage = undefined,
        };
        if (spill.len <= inline_capacity) {
            for (spill, 0..) |f, i| self.storage.inline_fields[i] = f;
        } else {
            self.storage = .{ .spilled = .{ .ptr = spill.ptr } };
        }
        return self;
    }
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
    regex: *const stg.Regex,
    kind: core.Literal.Kind,
    node: Node,
};

pub const State = union(enum) {
    unevaluated: Pending,
    /// The rest of a tree traversal, resumed by the evaluator rather than by
    /// running a term. An axis yields one cell at a time, so the tail of its
    /// list is one of these.
    traversing: Traversal,
    /// Entered and not yet finished. Re-entering is a cycle.
    evaluating,
    evaluated: Value,

    pub const Pending = struct {
        code: *const stg.Closure,
        captured: []const *Thunk,
    };
};

/// Where a suspended axis resumes.
///
/// Deliberately not a general continuation: an axis resumes at a node, and
/// widening this to an arbitrary callback invites primitives that Core could
/// express to become native.
pub const Traversal = struct {
    /// The cursor this walk advances. Owned by the machine, which reuses it
    /// once the walk runs out and frees every cursor when the run ends, so a
    /// walk a consumer abandons costs one allocation until then rather than
    /// leaking.
    ///
    /// `ts_node_next_sibling` rescans the parent's children on every call and
    /// ascends when it finds nothing, which makes a node-by-node walk
    /// quadratic in nesting depth. A cursor advances an index on its own
    /// stack instead.
    cursor: *ts.TreeCursor,
    move: Move,
    keep: Keep,

    pub const Move = enum {
        /// The next sibling.
        sibling,
        /// The pre-order successor within the subject's subtree.
        preorder,
    };

    /// Which nodes the walk yields. Field and kind ids are resolved when the
    /// query was desugared.
    pub const Keep = union(enum) {
        any,
        named,
        /// Nodes under this grammar field, named or anonymous.
        field: u16,
        /// Named nodes of this kind.
        kind: u16,
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

test "a thunk is run once and read thereafter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var literal = Thunk.value(.{ .number = 7 });
    const code: stg.Closure = .{ .free = &.{}, .parameters = &.{}, .body = .{ .atom = .{ .literal = &literal } } };
    const program: stg.Program = .{
        .definitions = &.{},
        .entry = undefined,
        .structural = undefined,
        .spellings = .empty,
        .tuples = .empty,
        .nil = undefined,
        .arena = &arena,
    };
    var machine = try @import("eval.zig").Machine.init(arena.allocator(), std.testing.allocator, &program);
    defer machine.deinit();

    var t: Thunk = .{ .state = .{ .unevaluated = .{ .code = &code, .captured = &.{} } } };
    try std.testing.expectEqual(7, (try machine.force(&t)).number);
    try std.testing.expect(t.state == .evaluated);

    literal = Thunk.value(.{ .number = 8 });
    try std.testing.expectEqual(7, (try machine.force(&t)).number);
}
