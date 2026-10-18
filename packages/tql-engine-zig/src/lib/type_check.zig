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
//!
//! ```tql
//! same :: Eq a => a -> a -> Bool;
//! same x y = x == y;
//! ```
//!
//! elaborates to `same = \d -> \x -> \y -> eq d x y`, and a call `same 1 2`
//! to `same` applied to the `Eq Int` dictionary, then `1` and `2`. Inference
//! meets the call before it may know the argument's type, so it can't pick
//! the dictionary there. Each use of a constrained name is applied to an
//! evidence variable instead, and raises a wanted for it. See Solving.
//!
//! `Serial` is the exception. Nothing calls its methods, since the machine
//! serializes `main`'s output itself, so it's checked like any other class
//! but has no dictionary.
//!
//! ## Solving
//!
//! A wanted is solved where it is generalized, not where it is raised. In
//!
//! ```tql
//! f x = let { same y = x == y; } in same 1;
//! ```
//!
//! the `==` in `same` raises `Eq a`, with `a` the type of `x`. `same` can't
//! take that dictionary as a parameter: `a` is in its environment, so `same`
//! isn't generalized over it, and no caller of `same` could pick an `Eq a`.
//! The wanted floats out to `f`, which is generalized over `a`, takes `Eq a`
//! as its context, and solves the wanted from its own parameter:
//!
//! ```
//! f = \d -> let ev = d in \x -> let same = \y -> eq ev x y in same 1
//! ```
//!
//! Each generalized body is a frame. A wanted is solved once, in the frame
//! it ends up in, from the givens in scope, their superclasses, then the
//! instances, and its evidence variable is bound by a `let` in that frame. A
//! later wanted for a constraint already solved there, or in an enclosing
//! frame, reuses the variable, so each constraint's dictionary is built
//! once. A wanted mentioning none of a frame's quantified variables floats
//! to the enclosing frame, and one on no variable at all, like `Eq Int`,
//! reaches the top and becomes a top-level definition.
//!
//! Solving any earlier gains nothing: until generalization a wanted's type
//! can still be a metavariable a later unification fixes, and the answer
//! doesn't change for having waited. Solving any later is too late, since
//! the wanted would have left the frame that has to bind its evidence.
//!
//! A wanted no rule solves is reported, a failed unification included, and
//! inference carries on. See Poisoned types.
//!
//! ## Poisoned types
//!
//! After an error, inference keeps going on types that are partly made up.
//! In
//!
//! ```tql
//! f x = 1 + "a";
//! g = not (f 1);
//! ```
//!
//! `1 + "a"` is a mismatch, yet `f` still gets the type `a -> Int`, and on
//! that type `not (f 1)` is a second mismatch, `Bool` against `Int`. Only
//! the `+` that already failed says `f` returns an `Int`, so the second
//! report restates the first.
//!
//! An error poisons the types it is about: each metavariable in them, and
//! whatever those are later bound to. An error about a poisoned type is
//! dropped. A use of an undefined name has a poisoned type, as does a use
//! of a definition whose type was poisoned when it was generalized, because
//! its scheme quantified the poisoned metavariables away. Here `f`'s result
//! is poisoned, so `f 1` is, and `not` takes it without a report.
//!
//! An ambiguity is an error about its constraint's type, so one
//! undetermined metavariable is reported once. An error that doesn't follow
//! from another is still reported, in a definition that has one too.
//!
//! ## Ambiguity
//!
//! A scheme is ambiguous when a constraint mentions a variable its type
//! doesn't. Consider
//!
//! ```tql
//! f x = if x == x then True else g 1;
//! g y = f (head []);
//! ```
//!
//! `f` and `g` are one group, so each is monomorphic inside it. `g` calls
//! `f (head [])`, which makes `f`'s argument `Maybe e`, and `x == x` needs
//! `Eq e`. Generalized, `f :: Eq e => Maybe e -> Bool` is fine. But every
//! member takes the group's context, so `g :: Eq e => Int -> Bool`. A caller
//! of `g` passes an `Int` and gets a `Bool`, and nothing it writes says what
//! `e` is, so no call can pick the dictionary. Reject `g` where it is
//! defined, not at its first use, which may be in another module or never.
//!
//! GHC gives each binder only the constraints its own type reaches, which
//! would leave `Eq e` out of `g`. That doesn't save `g`: its body still calls
//! `f` at `Maybe e`, so it still needs an `Eq e`, and now nothing passes one.
//! The error moves instead of going away, and the two choices accept the same
//! programs. A definition
//! with a signature is a component of its own (see Binding groups), so every
//! member of a group is monomorphic in it, and the group's dictionaries flow
//! through every member: each constraint the group raises is one every
//! member's evaluation depends on. So the group shares one context, and each
//! member's final scheme is checked.
//!
//! The check reads a type with its aliases expanded. With
//! `type Const a b = a`, `Eq b => Const Int b -> Int` mentions `b` only where
//! the expansion drops it, so it is ambiguous as well. Every scheme goes
//! through the same check: inferred, written in a signature or a method's,
//! and an instance's context against its head.
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
//! - Dimitrios Vytiniotis, Simon Peyton Jones, Tom Schrijvers and Martin
//!   Sulzmann. "OutsideIn(X): Modular type inference with local
//!   assumptions". Journal of Functional Programming 21(4-5), 2011,
//!   pp. 333-412.
//! - Simon Marlow (editor). "Haskell 2010 Language Report", 2010, section
//!   4.3.4, "Ambiguous Types, and Defaults for Overloaded Numeric
//!   Operations".

const erase = @import("type_check/erase.zig");
const infer = @import("type_check/infer.zig");
const substitution = @import("type_check/substitution.zig");
const unify = @import("type_check/unify.zig");

/// Why two types could not be made equal. Public because a diagnostic renders
/// it; the unifier itself is not.
pub const Mismatch = unify.Mismatch;

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

test "binding a poisoned metavariable poisons what it is bound to" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh(.type);
    const b = try t.subst.fresh(.type);
    const c = try t.subst.fresh(.type);
    t.subst.poison(a);
    t.subst.bind(a.meta, try core.datatypes.list(t.subst.arena, b));

    try std.testing.expect(t.subst.isPoisoned(b));
    try std.testing.expect(!t.subst.isPoisoned(c));
}

test "a metavariable bound to a poisoned one is poisoned" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh(.type);
    const b = try t.subst.fresh(.type);
    t.subst.poison(a);
    t.subst.bind(b.meta, a);

    try std.testing.expect(t.subst.isPoisoned(b));
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
