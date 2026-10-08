//! Core-to-Core simplification of a checked program.
//!
//! Each iteration analyses every binder's occurrences, then simplifies every
//! definition in one traversal, until no rewrite fires. That runs twice: first
//! holding back from inlining the functions a law matches on, then not.
//! Every rewrite is an
//! equation of the call-by-need lambda calculus or a law of the language, so
//! skipping this pass changes no observable result, and the corpus is run
//! both ways.
//!
//! Runs after inference, so a rewrite may assume its input type-checked.

const std = @import("std");
const core = @import("core.zig");
const occurrence = @import("core_to_core/occurrence.zig");
const simplify = @import("core_to_core/simplify.zig");

/// Which rewrites run.
pub const Options = @import("core_to_core/options.zig").Options;
const Simplifier = simplify.Simplifier;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

test {
    std.testing.refAllDecls(occurrence);
    std.testing.refAllDecls(simplify);
}

/// Simplify every definition in `program`, in place.
///
/// Terms are allocated from the program's own arena, so the rewritten program
/// owns its terms exactly as the desugared one did.
pub fn run(program: *core.Program, options: Options) Error!void {
    for ([_]simplify.Phase{ .laws, .final }) |phase| {
        for (0..options.max_iterations) |_| {
            if (!try iterate(program, options, phase)) break;
        }
    }
}

/// Analyse and simplify every definition once, each after the definitions
/// it may inline. Returns whether a rewrite fired.
fn iterate(program: *core.Program, options: Options, phase: simplify.Phase) Error!bool {
    var scratch: std.heap.ArenaAllocator = .init(program.env.gpa);
    defer scratch.deinit();

    const builder: core.Builder = .{ .allocator = program.env.allocator() };
    var occurrences: occurrence.Table = .init(scratch.allocator());
    var analyser: occurrence.Analyser = .{
        .scratch = scratch.allocator(),
        .builder = builder,
        .env = &program.env,
        .table = &occurrences,
        .drop_dead = options.dead_bindings,
    };
    const analysis = try analyser.program(program.definitions);
    var simplifier: Simplifier = .init(&analyser, &program.env, options, phase);

    const simplified = try builder.slice(core.Definition, program.definitions.len);
    for (analysis.order) |i| {
        const old = analysis.definitions[i];
        const body = try simplifier.simplify(old.body);
        simplified[i] = .{ .symbol = old.symbol, .body = body, .span = old.span };
        try simplifier.unfold(old.symbol, body);
    }
    program.definitions = simplified;
    return simplifier.changed;
}

test "the pass runs until no rewrite fires" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const false_ = try pb.global("False");
    const true_ = try pb.global("True");
    const go = try pb.local("go");
    const n = try pb.local("n");

    // `letrec go = \n -> case True of { False -> go n; True -> n } in go 1`:
    // the first iteration removes the recursion, the second the `let`.
    const recursion = try pb.case(pb.symbol(true_), &.{
        .{ .constructor = false_, .binders = &.{}, .body = try pb.apply(pb.symbol(go), &.{pb.symbol(n)}) },
        .{ .constructor = true_, .binders = &.{}, .body = pb.symbol(n) },
    });
    try pb.define(main, try pb.letrec(&.{
        .{ .name = go, .value = try pb.lambda(&.{n}, recursion) },
    }, try pb.apply(pb.symbol(go), &.{pb.number(1)})));
    var program = try pb.program(main);

    try run(&program, .{});
    try std.testing.expectEqual(1, program.definitions[0].body.kind.literal.number);
    try std.testing.expect(!try iterate(&program, .{}, .final));
}

/// Prints through `program`'s interner, which inlining has grown past the
/// builder's copy.
fn expectMain(program: *const core.Program, expected: []const u8) !void {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    const printer: core.Printer = .{ .interner = &program.env.interner };
    for (program.definitions) |definition| {
        if (definition.symbol == program.entry) try printer.term(definition.body, &w.writer);
    }
    try std.testing.expectEqualStrings(expected, w.written());
}

test "a global function applied to every argument it takes is inlined" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const double = try pb.global("double");
    const g = try pb.global("g");
    const x = try pb.local("x");

    try pb.define(main, try pb.apply(pb.symbol(double), &.{pb.number(1)}));
    try pb.define(double, try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{ pb.symbol(x), pb.symbol(x) })));
    var program = try pb.program(main);

    try run(&program, .{});
    try expectMain(&program, "g 1 1");
}

test "a loop breaker is not inlined" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const go = try pb.global("go");
    const n = try pb.local("n");

    try pb.define(go, try pb.lambda(&.{n}, try pb.apply(pb.symbol(go), &.{pb.symbol(n)})));
    try pb.define(main, try pb.apply(pb.symbol(go), &.{pb.number(1)}));
    var program = try pb.program(main);

    try run(&program, .{});
    try expectMain(&program, "go 1");
}

test "a function a law names is inlined only in the second phase" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const kleisli = try pb.global("kleisli");
    const concat_map = try pb.global("concat_map");
    const a = try pb.global("a");
    const b = try pb.global("b");
    const p = try pb.local("p");
    const q = try pb.local("q");
    const x = try pb.local("x");

    try pb.define(kleisli, try pb.lambda(&.{ p, q, x }, try pb.apply(pb.symbol(concat_map), &.{
        pb.symbol(q),
        try pb.apply(pb.symbol(p), &.{pb.symbol(x)}),
    })));
    try pb.define(main, try pb.apply(pb.symbol(kleisli), &.{ pb.symbol(a), pb.symbol(b), pb.number(1) }));
    var program = try pb.program(main);

    try std.testing.expect(!try iterate(&program, .{}, .laws));
    try expectMain(&program, "kleisli a b 1");
    try run(&program, .{});
    try expectMain(&program, "concat_map b (a 1)");
}

test "the laws can be switched off" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    for ([_]core.PrimOp{ .children, .of_kind, .children_of_kind }) |primop| {
        const id = try pb.env.interner.intern(.prelude, @tagName(primop), .{ .primop = primop });
        pb.env.primitives.set(primop, id);
    }
    const main = try pb.global("main");
    const kleisli = try pb.global("kleisli");
    const kind = pb.terms().literal(.{ .kind = .{ .name = "class", .id = 1 } }, .unknown);

    try pb.define(main, try pb.apply(pb.symbol(kleisli), &.{
        pb.symbol(pb.env.primitives.get(.children).?),
        try pb.apply(pb.symbol(pb.env.primitives.get(.of_kind).?), &.{kind}),
    }));
    var program = try pb.program(main);

    try run(&program, .{ .laws = false });
    try expectMain(&program, "kleisli children (of_kind :class)");
    try run(&program, .{});
    try expectMain(&program, "children_of_kind :class");
}

/// A program builder with `primops` as primitives.
fn kindTestFixture(primops: []const core.PrimOp) !core.test_support.ProgramBuilder {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    errdefer pb.deinit();
    for (primops) |primop| {
        const id = try pb.env.interner.intern(.prelude, @tagName(primop), .{ .primop = primop });
        pb.env.primitives.set(primop, id);
    }
    return pb;
}

/// `case of_kind :class subject of { Nil -> failed; Cons n t -> case t of {
/// Nil -> matched; Cons _ _ -> failed } }`.
fn kindCase(
    pb: *core.test_support.ProgramBuilder,
    subject: core.Term,
    n: core.SymbolId,
    matched: core.Term,
    failed: core.Term,
) !core.Term {
    const nil = pb.env.datatypes.nilConstructor().symbol;
    const cons = pb.env.datatypes.consConstructor().symbol;
    const t = try pb.local("t");
    const kind = pb.terms().literal(.{ .kind = .{ .name = "class", .id = 1 } }, .unknown);
    const rest = try pb.case(pb.symbol(t), &.{
        .{ .constructor = nil, .binders = &.{}, .body = matched },
        .{ .constructor = cons, .binders = &.{ try pb.local("_"), try pb.local("_") }, .body = failed },
    });
    return try pb.case(try pb.apply(pb.symbol(pb.env.primitives.get(.of_kind).?), &.{ kind, subject }), &.{
        .{ .constructor = nil, .binders = &.{}, .body = failed },
        .{ .constructor = cons, .binders = &.{ n, t }, .body = rest },
    });
}

test "a bind over an axis whose case tests a kind walks only that kind" {
    var pb = try kindTestFixture(&.{ .descendants, .of_kind, .is_kind, .descendants_of_kind });
    defer pb.deinit();
    const nil = pb.env.datatypes.nilConstructor().symbol;
    const main = try pb.global("main");
    const concat_map = try pb.global("concat_map");
    const f = try pb.global("f");
    const root = try pb.local("root");
    const s = try pb.local("s");
    const n = try pb.local("n");

    const matched = try pb.apply(pb.symbol(f), &.{ pb.symbol(n), pb.symbol(s) });
    try pb.define(main, try pb.lambda(&.{root}, try pb.apply(pb.symbol(concat_map), &.{
        try pb.lambda(&.{s}, try kindCase(&pb, pb.symbol(s), n, matched, pb.symbol(nil))),
        try pb.apply(pb.symbol(pb.env.primitives.get(.descendants).?), &.{pb.symbol(root)}),
    })));
    var program = try pb.program(main);

    try run(&program, .{});
    try expectMain(&program, "\\root -> concat_map (\\s -> f s s) (descendants_of_kind :class root)");
}

test "a case of a kind test on a local tests the kind and matches the local" {
    var pb = try kindTestFixture(&.{ .of_kind, .is_kind });
    defer pb.deinit();
    const main = try pb.global("main");
    const f = try pb.global("f");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const n = try pb.local("n");
    const matched = try pb.apply(pb.symbol(f), &.{pb.symbol(n)});
    try pb.define(main, try pb.lambda(&.{x}, try kindCase(&pb, pb.symbol(x), n, matched, pb.symbol(g))));
    var program = try pb.program(main);

    try run(&program, .{ .laws = false });
    try expectMain(&program,
        \\\x -> case of_kind :class x of
        \\  Nil -> g
        \\  Cons n t -> case t of
        \\    Nil -> f n
        \\    Cons _ _ -> g
    );
    try run(&program, .{});
    try expectMain(&program,
        \\\x -> case is_kind :class x of
        \\  False -> g
        \\  True -> f x
    );
}

test "a case of a kind test on a compound subject is left alone" {
    var pb = try kindTestFixture(&.{ .of_kind, .is_kind });
    defer pb.deinit();
    const main = try pb.global("main");
    const f = try pb.global("f");
    const g = try pb.global("g");
    const h = try pb.global("h");
    const x = try pb.local("x");
    const n = try pb.local("n");
    const subject = try pb.apply(pb.symbol(h), &.{pb.symbol(x)});
    const matched = try pb.apply(pb.symbol(f), &.{pb.symbol(n)});
    try pb.define(main, try pb.lambda(&.{x}, try kindCase(&pb, subject, n, matched, pb.symbol(g))));
    var program = try pb.program(main);

    try run(&program, .{});
    try expectMain(&program,
        \\\x -> case of_kind :class (h x) of
        \\  Nil -> g
        \\  Cons n t -> case t of
        \\    Nil -> f n
        \\    Cons _ _ -> g
    );
}
