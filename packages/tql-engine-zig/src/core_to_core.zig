//! Core-to-Core simplification of a checked program.
//!
//! Each iteration analyses every binder's occurrences, then simplifies every
//! definition in one traversal, until no rewrite fires. Every rewrite is an
//! equation of the call-by-need lambda calculus or a law of the language, so
//! skipping this pass changes no observable result, and the corpus is run
//! both ways.
//!
//! Runs after inference, so a rewrite may assume its input type-checked.

const std = @import("std");
const core = @import("core.zig");
const simplify = @import("core_to_core/simplify.zig");
const Simplifier = simplify.Simplifier;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

test {
    std.testing.refAllDecls(simplify);
}

/// Iterations before the pass stops short of a fixpoint.
pub const max_iterations = 4;

/// Simplify every definition in `program`, in place.
///
/// Terms are allocated from the program's own arena, so the rewritten program
/// owns its terms exactly as the desugared one did.
pub fn run(program: *core.Program) Error!void {
    for (0..max_iterations) |_| {
        if (!try iterate(program)) return;
    }
}

/// Analyse and simplify every definition once. Returns whether a rewrite
/// fired.
fn iterate(program: *core.Program) Error!bool {
    var scratch: std.heap.ArenaAllocator = .init(program.env.gpa);
    defer scratch.deinit();

    const builder: core.Builder = .{ .allocator = program.env.allocator() };
    var occurrences: core.occurrence.Table = .init(scratch.allocator());
    var analyser: core.occurrence.Analyser = .{
        .scratch = scratch.allocator(),
        .builder = builder,
        .interner = &program.env.interner,
        .table = &occurrences,
    };
    var simplifier: Simplifier = .init(builder, scratch.allocator(), &program.env, &occurrences);

    const analysed = try builder.slice(core.Definition, program.definitions.len);
    for (program.definitions, analysed) |old, *new| {
        new.* = .{ .symbol = old.symbol, .body = try analyser.analyse(old.body), .span = old.span };
    }
    const simplified = try builder.slice(core.Definition, program.definitions.len);
    for (analysed, simplified) |old, *new| {
        new.* = .{ .symbol = old.symbol, .body = try simplifier.simplify(old.body), .span = old.span };
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

    try run(&program);
    try std.testing.expectEqual(1, program.definitions[0].body.kind.literal.number);
    try std.testing.expect(!try iterate(&program));
}
