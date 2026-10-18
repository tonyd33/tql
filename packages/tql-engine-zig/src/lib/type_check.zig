//! Type checking: bidirectional Hindley-Milner inference over linked Core.
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
//! generalized over what's left. A signature, where there is one, is pushed
//! into the body it types. See Checking.
//!
//! ## Binding groups
//!
//! Generalizing too early loses information, and generalizing too late loses
//! polymorphism. Here `g` is used at two types:
//!
//! ```tql
//! f x = g x;
//! g y = y;
//! main = Kleisli $ \_ -> [(f 1, g "a")];
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
//! ## Levels
//!
//! A binding may only quantify the metavariables that are its own. In
//!
//! ```tql
//! f x = let { h y = f y; } in h x;
//! ```
//!
//! `f` is still being inferred, so its type is a placeholder, and `h y = f
//! y` makes `h`'s type that placeholder's argument and result. Quantifying
//! them in `h` would let `h 1` and `h "s"` both pass while `f` takes one
//! type. The textbook test walks every type in scope at each `let` for the
//! metavariables they mention.
//!
//! Each metavariable has a level instead, the depth of generalized bodies
//! it was made in, and a body at level `n` quantifies only metavariables
//! deeper than `n`. Binding a metavariable lowers every metavariable of its
//! solution to its own level, so one the environment can reach is never
//! deeper than the environment. Here `f`'s placeholder is at level 1 and
//! `h`'s parameter at level 2, and `f y` binds one to the other, which
//! leaves both at 1. `h` quantifies nothing.
//!
//! A signature's variables are skolems with a level of their own, and a
//! metavariable can't be bound to a type with a skolem deeper than itself:
//! the skolem would escape the signature binding it.
//!
//! ## Checking
//!
//! A signature is pushed into the body it types, not compared with the
//! body's type afterwards. In
//!
//! ```tql
//! f :: Int -> Int;
//! f x = do {
//!   let y = x + 1;
//!   return_string y;
//! };
//! ```
//!
//! the body infers `Int -> String`, and comparing that with the signature
//! can only blame the whole definition. Checked against `Int -> Int`
//! instead, the lambda gives `x` the `Int`, and the `Int` result reaches
//! `return_string y` through the `let`, which is the subterm that disagrees.
//!
//! So a term is either inferred or checked against an expected type. A
//! lambda checked against an arrow takes its parameter from the arrow, and
//! a `case` checks every branch. An application infers its function and
//! unifies the function's result with the expected type before it checks
//! the arguments. Checking the arguments first would infer each one without
//! what the context knows. In `if c then pure 1 else pure "two"`, the second
//! branch is checked against `f Int`, so `pure`'s argument is checked
//! against `Int`, and the error is at `"two"`, not at `pure "two"`. Any
//! other term is inferred and compared where it stands.
//!
//! A signature's variables become skolems, which are equal only to
//! themselves. `f :: a -> a; f = kind;` checks `kind` against `a -> a`, and
//! `Node` against the skolem `a` fails with `a` named as rigid. The body is
//! solved in an implication whose givens are the signature's context, so a
//! wanted on `a` the context doesn't give is reported where it was raised.
//!
//! ## Monomorphism restriction
//!
//! A binding written without parameters is computed once, and generalizing
//! it over a class would undo that. In
//!
//! ```tql
//! one = pure 1;
//! main = one;
//! ```
//!
//! `one :: Applicative f => f Int` would be a function of a dictionary,
//! rebuilt at each use. So a top-level group with a member written without
//! parameters quantifies none of the metavariables its context mentions.
//! They move to the enclosing level, their wanteds float out with them, and
//! the uses fix them: `one` is `Filter Node Int`, and its dictionary is
//! built once. A constrained metavariable no use fixes is ambiguous.
//!
//! The rule reads the definition as written, so `f = \x -> x == x` is
//! restricted where `f x = x == x` is not, as in Haskell 2010's Rule 1.
//!
//! ## Local bindings
//!
//! A local binding that mentions a variable of an enclosing lambda or
//! `case` alternative is not generalized. In
//!
//! ```tql
//! f x = let { pair y = { a = x, b = y }; } in pair 1;
//! ```
//!
//! `pair` could still quantify `y`'s type, since only `x`'s belongs to the
//! environment, and Levels tells the two apart. It isn't, after Vytiniotis,
//! Peyton Jones and Schrijvers: such bindings are hardly ever used at two
//! types, and a generalized binding is a frame of its own whose wanteds on
//! `x`'s type can only be solved outside it. Left monomorphic, `pair` is
//! inferred in `f`'s frame, and its wanteds are `f`'s from the start. A
//! closed binding, one that mentions only top-level names and other closed
//! bindings, is still generalized, and a local signature generalizes any
//! binding.
//!
//! ## Recursive groups
//!
//! A recursive binding takes its dictionaries once. In
//!
//! ```tql
//! member x ys = case ys of {
//!   Nil -> False;
//!   Cons y rest -> if x == y then True else member x rest;
//! };
//! ```
//!
//! `member :: Eq a => a -> [a] -> Bool` takes an `Eq a` dictionary. Treated
//! as any other use, the recursive call is applied to the dictionary again,
//! `member d x rest`, and evidence the body built from `d` is rebuilt on
//! every call. The call is at the very type being defined, so it needs
//! nothing passed. The group's dictionaries are bound once, around a
//! monomorphic copy that recurses directly, as GHC's AbsBinds does:
//!
//! ```
//! member = \d -> letrec { member' = \x -> \ys -> ... member' x rest } in member'
//! ```
//!
//! The members of a group share one context, so their copies sit in one
//! `letrec` under the same dictionaries. Only one value leaves it, though,
//! and each member is a binding of its own. GHC returns a tuple of the
//! copies. A tuple type here is declared by the linker with its derived
//! instances, too early to know which groups need one, so the `letrec`
//! returns a function handing its copies to a selector instead:
//!
//! ```
//! group = \d -> letrec { even' = ...; odd' = ... } in \k -> k even' odd'
//! even = \d -> group d (\e _ -> e)
//! ```
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
//! serializes `entry`'s output itself, so it's checked like any other class
//! but has no dictionary.
//!
//! ## Solving
//!
//! A wanted is solved where it is generalized, not where it is raised. In
//!
//! ```tql
//! f x = let { same y = y == x; } in same 1;
//! ```
//!
//! the `==` in `same` raises `Eq a`, with `a` the type of `x`. `same` can't
//! take that dictionary as a parameter: it mentions `x`, so it isn't
//! generalized (see Local bindings), and no caller of `same` could pick an
//! `Eq a` anyway. The wanted is `f`'s, which is generalized over `a`, takes
//! `Eq a` as its context, and solves the wanted from its own parameter:
//!
//! ```
//! f = \d -> let ev = d in \x -> let same = \y -> eq ev y x in same 1
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
//! f x = if x then 1 else "a";
//! g = not (f True);
//! ```
//!
//! the branches disagree, yet `f` still gets the type `Bool -> Int` from
//! the first, and on that type `not (f True)` is a second mismatch, `Bool`
//! against `Int`. Only a guess says `f` returns an `Int`, so the second
//! report restates the first.
//!
//! An error poisons the types it is about: each metavariable in them, and
//! whatever those are later bound to. An error about a poisoned type is
//! dropped. A use of an undefined name has a poisoned type, as does a use
//! of a definition whose type was poisoned when it was generalized, because
//! its scheme quantified the poisoned metavariables away. Here `"a"` is
//! checked against `f`'s result metavariable, which the mismatch poisons, so
//! `f True` is poisoned, and `not` takes it without a report.
//!
//! An error against a type the context fixed poisons nothing. In `f x = 1 +
//! "a"`, `"a"` fails against `+`'s `Int`, and `f` returns an `Int` whatever
//! its argument, so `not (f 1)` is an error of its own.
//!
//! In `h = pure (f True)`, `h` is `m t` with only `t` poisoned, and being
//! restricted (see Monomorphism restriction), it leaves `Applicative m` for
//! its uses to fix. But every use of `h` has a poisoned type of its own and
//! fixes nothing, so `m` would be reported as ambiguous after the mismatch it
//! follows from. A restricted group poisons each metavariable it leaves that
//! only its poisoned members mention. Poisoning `h`'s whole type instead
//! would reach metavariables of the enclosing scope, and drop later errors
//! about them that follow from nothing.
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
//! The machine runs a definition no module writes. The linker adds
//!
//! ```tql
//! entry = run_main main;
//! ```
//!
//! to the entry module, with `run_main :: Serial t => Filter Node t -> Node
//! -> [t]` from the library, and `entry` is checked like any definition
//! written without parameters. `main` gets no rule of its own: one that isn't
//! a filter from nodes is a mismatch at its use in `entry`, and `entry` wants
//! `Serial` of its output.
//!
//! The output must be determined only as far as that constraint needs. In
//!
//! ```tql
//! main = Kleisli $ \_ -> [];
//! ```
//!
//! nothing says what `main` would return, so `Serial t` is ambiguous. But
//! with `data P a = P deriving (Serial)`, `main = pure P` leaves `a` free and
//! is fine: `Serial (P a)` holds whatever `a` is.
//!
//! ## Newtypes
//!
//! A `newtype` is a distinct type to the checker, which is what lets
//! `Kleisli m a b` have instances a plain function doesn't. Once checking is
//! done, the distinction has served its purpose, so erasure removes the
//! constructor entirely: `Kleisli f` becomes `f`.
//!
//! Matching on a newtype doesn't force anything. `case e of
//! { Kleisli g -> 1 }` becomes `let g = e in 1`, which is `1` even when `e` is
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
//! - Simon Peyton Jones, Dimitrios Vytiniotis, Stephanie Weirich and Mark
//!   Shields. "Practical type inference for arbitrary-rank types". Journal
//!   of Functional Programming 17(1), 2007, pp. 1-82.
//! - George Kuan and David MacQueen. "Efficient type inference using ranked
//!   type variables". ML Workshop, 2007.
//! - Dimitrios Vytiniotis, Simon Peyton Jones and Tom Schrijvers. "Let
//!   should not be generalised". TLDI 2010, pp. 39-50.
//! - Dimitrios Vytiniotis, Simon Peyton Jones, Tom Schrijvers and Martin
//!   Sulzmann. "OutsideIn(X): Modular type inference with local
//!   assumptions". Journal of Functional Programming 21(4-5), 2011,
//!   pp. 333-412.
//! - Simon Marlow (editor). "Haskell 2010 Language Report", 2010, section
//!   4.3.4, "Ambiguous Types, and Defaults for Overloaded Numeric
//!   Operations", and section 4.5.5, "The Monomorphism Restriction".

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
