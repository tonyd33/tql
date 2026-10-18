//! Desugaring: TQL source to Core.
//!
//! ## What a query means
//!
//! TQL has no semantics of its own. A query means what the Core it desugars
//! to means, and `core.zig` says what that is. So this pass is where each
//! piece of surface syntax gets its meaning, the way the Haskell Report
//! defines `do` and list comprehensions by translation into a smaller
//! kernel.
//!
//! The translations, read left to right:
//!
//! ```
//! \x y -> e                  \x -> \y -> e
//! f x y = e                  f = \x -> \y -> e
//! if c then t else f         case c of { False -> f; True -> t }
//! [e_1, .., e_n]             Cons e_1 (.. (Cons e_n Nil) ..)
//! e_1 : e_2                  Cons e_1 e_2
//! (e_1, .., e_n)             the n-tuple constructor applied to e_1 .. e_n
//! {l_1 = e_1, ..}            record[l_1,..] e_1 ..      (labels sorted)
//! e.l                        select[l] e
//! (.l)                       select[l]
//! (.l_1.l_2)                 \x -> select[l_2] (select[l_1] x)
//! p | q                      compose_flipped p q
//! p . q                      compose p q
//! p <|> q                    alt p q
//! e_1 >> e_2                 bind e_1 (\_ -> e_2)
//! e_1 == e_2                 eq e_1 e_2
//! e_1 != e_2                 case eq e_1 e_2 of { False -> True; True -> False }
//! e_1 < e_2                  case compare e_1 e_2 of { LT -> True; EQ -> False; GT -> False }
//! e_1 + e_2                  op[+] e_1 e_2
//! #f                         Filter field[f]
//! e#f                        field[f] e
//! (op e)                     \x -> x op e
//! do { x <- e; s; r }        bind e (\x -> do { s; r })
//! do { e; s; r }             bind e (\_ -> do { s; r })
//! let { b; .. } in e         a let or letrec per binding group of b ..
//! case e of { alts }         see match.zig
//! ```
//!
//! The other comparisons follow `<`, with the alternatives answering as the
//! comparison does. `bind`, `compose` and the rest are whatever the library
//! defines them as, found by what they are rather than by name, so a query
//! that shadows `bind` doesn't change what `do` means.
//!
//! A `do` bind whose pattern can fail yields `empty` for each value it
//! doesn't match, so `Just x <- e` skips the `Nothing`s.
//!
//! Note that a section binds a compound operand outside its lambda, so
//! `(op f x)` evaluates `f x` at most once, however often the section is
//! called.

const annotation = @import("tql_to_core/annotation.zig");
const desugar = @import("tql_to_core/desugar.zig");
const link_mod = @import("tql_to_core/link.zig");

/// Desugars source files into one linked `core.Program`.
pub const Desugarer = link_mod.Desugarer;
pub const Import = scope_mod.Import;
pub const Filter = scope_mod.Filter;
pub const Exports = scope_mod.Exports;

test {
    std.testing.refAllDecls(link_mod);
    std.testing.refAllDecls(desugar);
    std.testing.refAllDecls(@import("tql_to_core/resolve.zig"));
    std.testing.refAllDecls(@import("tql_to_core/scope.zig"));
    std.testing.refAllDecls(annotation);
    std.testing.refAllDecls(@import("tql_to_core/classes.zig"));
}

const std = @import("std");
const core = @import("core.zig");
const cst = @import("lang/cst.zig");
const diagnostic = @import("diagnostic.zig");
const test_support = core.test_support;
const scope_mod = @import("tql_to_core/scope.zig");
const ModuleScope = scope_mod.ModuleScope;

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Translates hand-built `cst.Type` signatures against an environment holding
/// the structural types.
const Fixture = struct {
    env: core.env.Env,
    sink: diagnostic.Sink,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try test_support.env(gpa),
            .sink = diagnostic.Sink.init(gpa),
        };
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.sink.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    /// `Prim`'s own view: every structural type, no imports.
    fn scope(self: *Fixture) ModuleScope {
        return .{
            .module = .prim,
            .imports = &.{},
            .visible = &.{},
            .exports = &.{},
            .env = &self.env,
        };
    }

    fn node(self: *Fixture, kind: cst.Type.Kind) cst.Type {
        _ = self;
        return .{ .kind = kind, .span = diagnostic.Span.unknown };
    }
};

/// `v0 -> v1 -> ... -> Int` over `count` distinct variables.
fn manyVariables(fix: *Fixture, count: usize) !cst.Type {
    const arena = fix.env.allocator();
    var t = fix.node(.{ .constructor = "Int" });
    var i = count;
    while (i > 0) {
        i -= 1;
        const arrow = try arena.create(cst.FunctionType);
        arrow.* = .{
            .from = fix.node(.{ .variable = try std.fmt.allocPrint(arena, "v{d}", .{i}) }),
            .to = t,
        };
        t = fix.node(.{ .function = arrow });
    }
    return t;
}

test "a signature may have as many variables as a scheme can number" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{ .name = "f", .type = try manyVariables(fix, 255) };
    const translated = try annotation.translate(fix.env.allocator(), gpa, &signature, &fix.scope(), &fix.sink);
    try testing.expectEqual(255, translated.scheme.variables.len);
}
