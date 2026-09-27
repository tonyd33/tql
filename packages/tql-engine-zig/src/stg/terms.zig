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
//! It adds two annotations inference never needed: a closure's free
//! variables, and the arity of every application.
//!
//! A binder is the SymbolId resolution interned for it. The evaluator looks it
//! up in an environment; nothing here assigns frame slots.
//!
//! Arguments are atoms. A compound argument is let-bound to a thunk before it
//! is passed, so `Cons h (append t ys)` cannot be spelled.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const primitives = @import("../primitives.zig");
const pcre2 = @import("../regex.zig");
const value = @import("value.zig");

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
    global: Global,
    /// Already evaluated, so the machine never writes it and every run of the
    /// program shares it.
    literal: *value.Thunk,
};

/// A top-level definition, by its position in `Program.definitions`.
pub const Global = struct {
    index: u32,
    symbol: core.SymbolId,
};

/// A regex literal: the pattern as written, and the program compiled from it.
/// Owned by the `Program` it appears in.
pub const Regex = struct {
    pattern: []const u8,
    compiled: pcre2.Regex,
};

/// A closure of no parameters is a thunk, which entering overwrites with its
/// result. One with parameters is a function, already a value.
pub const Closure = struct {
    /// The free variables the body reads, as offsets into the *enclosing*
    /// environment. Read at allocation and copied, so the closure outlives the
    /// scope it was written in.
    free: []const Local,
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
        /// The symbol it was reached through, for printing.
        symbol: core.SymbolId,
        /// What a synthesized symbol resolved to: the kind or field id, the
        /// operator, or the record labels. `op[+]` and `op[-]` share a PrimOp
        /// and are told apart here. Owned by the program.
        synthesized: ?core.Synthesized,
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

/// A constructor the machine builds or recognizes itself.
pub const Builtin = struct {
    symbol: core.SymbolId,
    tag: u32,
};

/// The constructors of `List` and `Bool`, which primitives build directly and
/// serialization encodes specially.
pub const Structural = struct {
    nil: Builtin,
    cons: Builtin,
    false_: Builtin,
    true_: Builtin,

    pub fn boolean(self: Structural, b: bool) Builtin {
        return if (b) self.true_ else self.false_;
    }
};

/// A translated program, and the arena its terms live in.
pub const Program = struct {
    definitions: []const Definition,
    entry: core.SymbolId,
    structural: Structural,
    /// An evaluated `Nil`, shared the way a literal atom's thunk is.
    nil: *value.Thunk,
    arena: *std.heap.ArenaAllocator,
    /// Every regex literal the terms reference. Their compiled programs are
    /// allocated outside the arena.
    regexes: []const *Regex = &.{},

    /// Held by pointer: moving an `ArenaAllocator` struct dangles every
    /// allocation made through it.
    pub fn deinit(self: *Program) void {
        for (self.regexes) |regex| regex.compiled.deinit();
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
    var one = value.Thunk.value(.{ .number = 1 });
    var two = value.Thunk.value(.{ .number = 2 });
    const alternatives = [_]Alternative{
        .{ .constructor = @enumFromInt(0), .tag = 0, .binders = &.{}, .body = .{ .atom = .{ .literal = &one } } },
        .{ .constructor = @enumFromInt(1), .tag = 1, .binders = &pair, .body = .{ .atom = .{ .literal = &two } } },
    };
    for (alternatives, 0..) |alternative, i| {
        try std.testing.expectEqual(i, alternative.tag);
    }
}
