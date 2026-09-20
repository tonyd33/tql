//! The STG-shaped term language the evaluator runs.
//!
//! ```
//! atom ::= var | literal
//!
//! expr ::= atom
//!        | f a_1 ... a_n
//!        | C a_1 ... a_n
//!        | prim a_1 ... a_n
//!        | case expr of { C x_1 .. x_n -> expr; ... }
//!        | let x = closure in expr
//!        | letrec { x = closure; ... } in expr
//!
//! closure ::= {v_1 .. v_k} \pi {x_1 .. x_n} -> expr
//!           | CON(C, a_1 .. a_n)
//! ```
//!
//! Core is what the type checker validated; this is what the evaluator walks.
//! It adds three annotations inference never needed: a closure's free
//! variables, its update flag, and the arity of every application.
//!
//! A binder is the SymbolId resolution interned for it. The evaluator looks it
//! up in an environment; nothing here assigns frame slots.
//!
//! Arguments are atoms. A compound argument is let-bound to a thunk before it
//! is passed, so `Cons h (append t ys)` cannot be spelled.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const builtin = @import("../builtin.zig");

const Allocator = std.mem.Allocator;

/// Where a local sits in the environment, and the name it was compiled from.
///
/// The environment is a closure's captures followed by its frame, laid out
/// contiguously, so one numbering covers both: an offset below the capture
/// count reads a capture and the rest read the frame. The name is carried for
/// printing and for the debug check that the slot holds what the atom meant.
pub const Local = struct {
    offset: u32,
    name: core.SymbolId,
};

/// An argument. Never a compound expression.
pub const Atom = union(enum) {
    local: Local,
    global: core.SymbolId,
    literal: core.Literal,
};

/// Whether entering this closure overwrites it with its result.
pub const Update = enum { updatable, single_entry };

pub const Closure = struct {
    /// The free variables the body reads, as offsets into the *enclosing*
    /// environment. Read at allocation and copied, so the closure outlives the
    /// scope it was written in.
    free: []const Local,
    update: Update,
    parameters: []const core.SymbolId,
    body: Expr,
};

/// A saturated constructor application.
pub const Constructed = struct {
    constructor: core.SymbolId,
    tag: u32,
    fields: []const Atom,
};

pub const Binding = struct {
    binder: core.SymbolId,
    value: Allocation,
};

pub const Allocation = union(enum) {
    closure: *const Closure,
    constructed: *const Constructed,
};

pub const Alternative = struct {
    constructor: core.SymbolId,
    tag: u32,
    /// One per constructor field, bound to it in field order.
    binders: []const core.SymbolId,
    body: Expr,
};

pub const Expr = union(enum) {
    atom: Atom,
    apply: *const Apply,
    constructed: *const Constructed,
    primitive: *const Primitive,
    case: *const Case,
    let: *const Let,

    pub const Apply = struct {
        callee: Atom,
        arguments: []const Atom,
    };

    pub const Primitive = struct {
        primop: core.PrimOp,
        /// The symbol it was reached through. `op[+]` and `op[-]` share a
        /// PrimOp; look this up in the details table to tell them apart.
        symbol: core.SymbolId,
        arguments: []const Atom,
    };

    pub const Case = struct {
        scrutinee: Expr,
        /// In the datatype's tag order, covering every constructor exactly
        /// once, so the tag indexes this directly.
        alternatives: []const Alternative,
    };

    pub const Let = struct {
        bindings: []const Binding,
        /// A `letrec` allocates every binding before evaluating any, so a
        /// binding may reference a later one.
        recursive: bool,
        body: Expr,
    };
};

pub const Definition = struct {
    symbol: core.SymbolId,
    /// A global is a thunk of no arguments, even when its body is a
    /// constructor application.
    value: *const Closure,
};

/// A translated program, and the arena its terms live in.
pub const Program = struct {
    definitions: []const Definition,
    entry: core.SymbolId,
    arena: *std.heap.ArenaAllocator,

    /// Held by pointer: moving an `ArenaAllocator` struct dangles every
    /// allocation made through it.
    pub fn deinit(self: *Program) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

test "an alternative's position is its tag" {
    // The evaluator indexes `alternatives` by the scrutinee's tag rather than
    // searching for a matching constructor, which is only sound while the
    // translation keeps them in tag order.
    const pair = [_]core.SymbolId{ @enumFromInt(7), @enumFromInt(8) };
    const alternatives = [_]Alternative{
        .{ .constructor = @enumFromInt(0), .tag = 0, .binders = &.{}, .body = .{ .atom = .{ .literal = .{ .number = 1 } } } },
        .{ .constructor = @enumFromInt(1), .tag = 1, .binders = &pair, .body = .{ .atom = .{ .literal = .{ .number = 2 } } } },
    };
    for (alternatives, 0..) |alternative, i| {
        try std.testing.expectEqual(i, alternative.tag);
    }
}

test "a thunk is a closure of no arguments that updates" {
    const body: Expr = .{ .atom = .{ .literal = .{ .number = 1 } } };
    const one = [_]core.SymbolId{@enumFromInt(1)};
    const thunk: Closure = .{ .free = &.{}, .update = .updatable, .parameters = &.{}, .body = body };
    const function: Closure = .{ .free = &.{}, .update = .single_entry, .parameters = &one, .body = body };

    try std.testing.expectEqual(0, thunk.parameters.len);
    try std.testing.expectEqual(Update.updatable, thunk.update);
    try std.testing.expectEqual(Update.single_entry, function.update);
}
