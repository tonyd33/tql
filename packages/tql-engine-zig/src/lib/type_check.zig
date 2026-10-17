//! Type checking: Hindley-Milner inference over linked Core.
//!
//! ## What the checker promises
//!
//! The machine has an `error.TypeError` for applying a number to an
//! argument, or for a `case` that meets a constructor none of its
//! alternatives name. A program that passes this checker never reaches it.
//! That's Milner's "well-typed programs cannot go wrong", and it's what lets
//! every pass after this one assume its input makes sense. See the second
//! paragraph of `core.zig`.
//!
//! No annotations are needed for it. Inference is Damas and Milner's
//! Algorithm W: every term gets a type with metavariables standing for what
//! isn't known yet, unification solves them, and a `let` binding is
//! generalized over what's left. A signature, where there is one, is checked
//! against what was inferred.
//!
//! ## Binding groups
//!
//! Generalizing too early loses information, and generalizing too late loses
//! polymorphism. Consider
//!
//! ```tql
//! f x = g x;
//! g y = y;
//! main = Filter (\_ -> [(f 1, g "a")]);
//! ```
//!
//! Checked as one group, `f` and `g` share one monomorphic type until the
//! group is done, and `g` used at both `Int` and `String` fails. But `g`
//! doesn't need `f` at all. So definitions are checked one strongly
//! connected component of the reference graph at a time, in dependency
//! order: `g` is generalized first, and `f` and `main` use it at whatever
//! type they like. Only genuinely mutually recursive definitions share a
//! group. A definition with a signature is a component of its own, since
//! every use of it, recursive ones included, is at the signature.
//!
//! ## Classes
//!
//! A class constraint becomes a dictionary argument, after Wadler and Blott.
//! Consider
//!
//! ```tql
//! same :: Eq a => a -> a -> Bool;
//! same x y = x == y;
//! ```
//!
//! which elaborates to `same = \d -> \x -> \y -> eq d x y`, and a call
//! `same 1 2` to `same` applied to the `Eq Int` dictionary, then `1` and
//! `2`. Inference can't pick that dictionary when it meets the call, though,
//! because the argument's type may not be known yet. So each use of a constrained name is applied to a placeholder, and
//! once inference is done, every placeholder resolves to a dictionary in
//! scope, a superclass selected from one, or an instance applied to the
//! evidence for its context. See `type_check/evidence.zig`.
//!
//! `Serial` is the exception. Nothing calls its methods, since the machine
//! serializes `main`'s output itself, so it's checked like any other class
//! but has no dictionary.
//!
//! ## main
//!
//! `main` gets three checks beyond its own inference. Its type must be
//! `Filter Node t`, since the machine applies it to the root node. `t` must
//! have a `Serial` instance, since each result is printed as JSON. And `t`
//! must be determined. Consider
//!
//! ```tql
//! main = Filter (\_ -> []);
//! ```
//!
//! It returns nothing, but nothing says what it would return either, so
//! there's no telling which `Serial` instance applies. It's rejected as
//! ambiguous rather than guessed at.
//!
//! ## Newtypes
//!
//! A `newtype` is a distinct type to the checker, which is what lets
//! `Filter a b` have instances a plain function doesn't. Once checking is
//! done, the distinction has served its purpose, so erasure removes the
//! constructor entirely: `Filter f` becomes `f`.
//!
//! Note that matching on a newtype doesn't force anything. `case e of
//! { Filter g -> 1 }` becomes `let g = e in 1`, which is `1` even when `e` is
//! `_|_`. That's the only reading under which erasing the constructor keeps
//! the meaning, so it's the meaning the checker gives it too.
//!
//! ## References
//!
//! - Robin Milner. "A theory of type polymorphism in programming". Journal
//!   of Computer and System Sciences 17, 1978, pp. 348-375.
//! - Luis Damas and Robin Milner. "Principal type-schemes for functional
//!   programs". POPL 1982, pp. 207-212.
//! - Philip Wadler and Stephen Blott. "How to make ad-hoc polymorphism less
//!   ad hoc". POPL 1989, pp. 60-76.
//! - Mark P. Jones. "Typing Haskell in Haskell". Haskell Workshop, 1999.

const constraints = @import("type_check/constraints.zig");
const erase = @import("type_check/erase.zig");
const infer = @import("type_check/infer.zig");
const substitution = @import("type_check/substitution.zig");
const unify = @import("type_check/unify.zig");

/// Why two types could not be made equal. Public because a diagnostic renders
/// it; the unifier itself is not.
pub const Mismatch = unify.Mismatch;

/// A constraint no instance satisfies, with the term that introduced it.
/// Public for the same reason: a diagnostic renders it.
pub const Violation = constraints.Violation;

/// Type-checks a linked program, writing each definition's scheme into its
/// environment and reporting through a `diagnostic.Sink`, then erases every
/// `newtype`.
pub fn check(gpa: std.mem.Allocator, program: *core.Program, sink: *diagnostic.Sink) !void {
    try infer.check(gpa, program, sink);
    try erase.program(program);
}

pub const Error = infer.Error;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(constraints);
    refAllDecls(erase);
    refAllDecls(infer);
    refAllDecls(substitution);
    refAllDecls(unify);
}

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");
const primitives = @import("primitives.zig");
const test_support = core.test_support;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Substitution = substitution.Substitution;

/// A substitution over one environment.
const Fixture = struct {
    pb: test_support.ProgramBuilder,
    subst: Substitution,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .pb = try test_support.ProgramBuilder.init(gpa),
            .subst = undefined,
        };
        self.subst = Substitution.init(gpa, self.pb.env.allocator(), &self.pb.env.datatypes, &self.pb.env.classes);
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.subst.deinit();
        self.pb.deinit();
        gpa.destroy(self);
    }
};

test "occurs check sees through a solved metavariable" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh(.type);
    const b = try t.subst.fresh(.type);
    t.subst.bind(b.meta, try core.datatypes.list(t.subst.arena, a));

    // `a` is not syntactically in `b`, but it is once `b` is resolved.
    try std.testing.expect(t.subst.occurs(a.meta, b));
}

test "a record scheme at the field ceiling still builds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, primitives.max_record_fields);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    const scheme = try primitives.synthesizedScheme(fix.pb.env.allocator(), &fix.pb.env.datatypes, .{ .record = labels });
    try testing.expectEqual(primitives.max_record_fields, scheme.variables.len);
}
