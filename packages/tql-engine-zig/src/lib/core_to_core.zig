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

test "a method of a dictionary built in place becomes its field" {
    var pb = try core.test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const e = &pb.env;
    const class = try e.classes.declare(.{ .name = .{ .module = .prelude, .name = "Describe" } });
    const describe = try e.interner.intern(.prelude, "describe", .{ .method = .{ .class = class, .index = 0 } });
    e.classes.getMut(class).methods = try e.allocator().dupe(core.SymbolId, &.{describe});
    const constructor = try pb.global("dict[Describe]");
    e.classes.getMut(class).constructor = constructor;
    const main = try pb.global("main");
    const f = try pb.global("f");
    const xs = try pb.global("xs");
    const dictionary = try pb.apply(pb.symbol(constructor), &.{pb.symbol(f)});

    try pb.define(main, try pb.apply(pb.symbol(describe), &.{ dictionary, pb.symbol(xs) }));
    var program = try pb.program(main);
    try run(&program, .{});
    try expectMain(&program, "f xs");
}
