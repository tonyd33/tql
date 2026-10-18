//! Lowering: checked Core to STG terms.
//!
//! ## Why the machine computes what Core means
//!
//! `core.zig` gives a term a meaning, and `stg/eval.zig` gives rules for
//! running one. Nothing so far says the two agree. If they didn't, every
//! argument the simplifier makes about meaning would be about a program
//! nobody runs.
//!
//! There are two gaps to close. First, translation must not change the
//! meaning. Read an STG term back as Core by forgetting its annotations: a
//! closure's free variable list, the grouping of a call's arguments, and the
//! difference between `let-no-escape` and `let`. Then translation keeps the
//! meaning when every step it takes is an equation of Core, and each one is:
//!
//! - Atomizing an argument turns `f e` into `let t = e in f t`. With `t`
//!   fresh, both mean `[[f]] env ([[e]] env)`.
//! - Collecting a spine turns `((f a) b) c` into one call of three
//!   arguments. Partial and Exact apply them in the same order as one at a
//!   time.
//! - A constructor or primitive used as a value becomes its wrapper, `C` to
//!   `\f_1 .. f_n -> C f_1 .. f_n`. That's eta expansion, which holds here
//!   because `C` is a value. See Lifted functions in `core.zig`.
//! - A join point becomes `let-no-escape`, which means what the `let` did.
//!
//! Second, the rules must compute the meaning. Launchbury proved his natural
//! semantics correct with respect to a denotational semantics like the one
//! in `core.zig`: if a term evaluates to a value, that value is its meaning.
//! Adequacy, the converse, that a term whose meaning isn't `_|_` does
//! evaluate, had a gap in his proof that Breitner closed.
//!
//! Note that both proofs are for Launchbury's language, which is smaller
//! than ours: no constructors, no `case`, no primitives, and no eval/apply.
//! The extensions are the standard ones, and we rely on the results carrying
//! over rather than on a proof for this machine. Note also the one place the
//! machine falls short of the meaning on purpose: it can run out of stack.
//!
//! ## References
//!
//! - John Launchbury. "A natural semantics for lazy evaluation". POPL 1993,
//!   pp. 144-154.
//! - Joachim Breitner. "The adequacy of Launchbury's natural semantics for
//!   lazy evaluation". Journal of Functional Programming 28, 2018.

const translate_mod = @import("core_to_stg/translate.zig");

/// Translates a checked program into the term language.
pub const translate = translate_mod.translate;

/// One program's translation state.
pub const Translator = translate_mod.Translator;

pub const Error = translate_mod.Error;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(translate_mod);
}

const std = @import("std");
const core = @import("core.zig");
const stg = @import("stg.zig");

const Allocator = std.mem.Allocator;

/// Walks translated terms, building each environment the way the evaluator
/// does, and fails on a local whose offset reads a slot bound to another name
/// or a global whose index names another definition.
const Placement = struct {
    gpa: Allocator,
    program: *const stg.Program,

    /// Spelled out because `closure` and `expr` are mutually recursive.
    const Failure = Allocator.Error || error{ TestUnexpectedResult, TestExpectedEqual };

    fn closure(self: Placement, c: *const stg.Closure, enclosing: []const core.SymbolId) Failure!void {
        var scope: std.ArrayList(core.SymbolId) = .empty;
        defer scope.deinit(self.gpa);
        for (c.free) |capture| {
            try expectLocal(capture, enclosing);
            try scope.append(self.gpa, capture.name);
        }
        try scope.appendSlice(self.gpa, c.parameters);
        try self.expr(c.body, &scope);
    }

    fn expr(self: Placement, e: stg.Expr, scope: *std.ArrayList(core.SymbolId)) Failure!void {
        switch (e) {
            .atom => |a| try self.atom(a, scope.items),
            .apply => |a| {
                try self.atom(a.callee, scope.items);
                for (a.arguments) |argument| try self.atom(argument, scope.items);
            },
            .constructed => |c| for (c.fields) |field| try self.atom(field, scope.items),
            .primitive => |p| for (p.arguments) |argument| try self.atom(argument, scope.items),
            .case => |c| {
                const start = scope.items.len;
                try self.expr(c.scrutinee, scope);
                scope.shrinkRetainingCapacity(start);
                if (c.binder) |binder| try scope.append(self.gpa, binder);
                const mark = scope.items.len;
                for (c.alternatives) |slot| {
                    const alternative = slot orelse continue;
                    try scope.appendSlice(self.gpa, alternative.binders);
                    try self.expr(alternative.body, scope);
                    scope.shrinkRetainingCapacity(mark);
                }
                if (c.default) |default| try self.expr(default, scope);
            },
            .let => |let| {
                const base = scope.items.len;
                for (let.bindings) |binding| try scope.append(self.gpa, binding.binder);
                const inner = if (let.recursive) scope.items else scope.items[0..base];
                for (let.bindings) |binding| switch (binding.value) {
                    .closure => |c| try self.closure(c, inner),
                    .constructed => |c| for (c.fields) |field| try self.atom(field, inner),
                };
                try self.expr(let.body, scope);
            },
            .let_no_escape => |let| {
                const depth = scope.items.len;
                for (let.joins) |join| {
                    try std.testing.expectEqual(depth, join.depth);
                    try scope.appendSlice(self.gpa, join.parameters);
                    try self.expr(join.body, scope);
                    scope.shrinkRetainingCapacity(depth);
                }
                try self.expr(let.body, scope);
            },
            .jump => |jump| {
                try std.testing.expectEqual(jump.target.parameters.len, jump.arguments.len);
                try std.testing.expect(jump.target.depth <= scope.items.len);
                for (jump.arguments) |argument| try self.atom(argument, scope.items);
            },
        }
    }

    fn atom(self: Placement, a: stg.Atom, scope: []const core.SymbolId) !void {
        switch (a) {
            .local => |local| try expectLocal(local, scope),
            .global => |g| {
                try std.testing.expect(g.index < self.program.definitions.len);
                try std.testing.expectEqual(g.symbol, self.program.definitions[g.index].symbol);
            },
            .literal => {},
        }
    }

    fn expectLocal(local: stg.Local, scope: []const core.SymbolId) !void {
        try std.testing.expect(local.offset < scope.len);
        try std.testing.expectEqual(local.name, scope[local.offset]);
    }
};

/// Checks the placement of every local and global in every definition of
/// `program`.
pub fn expectPlaced(gpa: Allocator, program: *const stg.Program) !void {
    const placement: Placement = .{ .gpa = gpa, .program = program };
    for (program.definitions) |definition| try placement.closure(definition.value, &.{});
}
