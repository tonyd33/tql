//! Core-to-Core simplification of a checked program.
//!
//! A simplifier run iterates until no rewrite fires or its iterations run
//! out. Each iteration drops the definitions `main` does not reach, analyses
//! every binder's occurrences, then simplifies every definition in one
//! traversal. After a run, each dictionary every call of a function passes
//! the same is substituted, and if one was, another run follows, for a
//! bounded number of rounds. Each phase runs this: first holding back from
//! inlining the functions a law matches on, then not.
//!
//! Every rewrite is an equation of the call-by-need lambda calculus or a law
//! of the language, so skipping this pass changes no observable result, and
//! the corpus is run both ways.
//!
//! Runs after inference, so a rewrite may assume its input type-checked.

const std = @import("std");
const core = @import("core.zig");
const occurrence = @import("core_to_core/occurrence.zig");
const simplify = @import("core_to_core/simplify.zig");
const dictionaries = @import("core_to_core/dictionaries.zig");
const laws = @import("core_to_core/laws.zig");

/// Which rewrites run.
pub const Options = @import("core_to_core/options.zig").Options;
const Simplifier = simplify.Simplifier;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

test {
    std.testing.refAllDecls(occurrence);
    std.testing.refAllDecls(simplify);
    std.testing.refAllDecls(dictionaries);
}

/// Simplify every definition in `program`, in place.
///
/// Terms are allocated from the program's own arena, so the rewritten program
/// owns its terms exactly as the desugared one did.
pub fn run(program: *core.Program, options: Options) Error!void {
    for ([_]simplify.Phase{ .laws, .final }) |phase| {
        var rounds: u32 = 0;
        while (true) : (rounds += 1) {
            try runSimplifier(program, options, phase);
            if (rounds == options.max_substitution_rounds or !try substitute(program, options)) break;
        }
    }
}

/// Iterate until no rewrite fires, for at most `options.max_iterations`.
///
/// Postconditions:
/// - With `options.dead_bindings`, every definition is reachable from `main`.
fn runSimplifier(program: *core.Program, options: Options, phase: simplify.Phase) Error!void {
    for (0..options.max_iterations) |_| {
        if (options.dead_bindings) try dropUnreachable(program);
        if (!try iterate(program, options, phase)) return;
        if (std.debug.runtime_safety) try expectJoinPointsHold(program);
    }
    if (options.dead_bindings) try dropUnreachable(program);
}

/// Drop every definition `main` does not reach. A symbol reaches each method
/// a law may select from it.
fn dropUnreachable(program: *core.Program) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(program.env.gpa);
    defer scratch.deinit();
    var reached: Reached = .{
        .scratch = scratch.allocator(),
        .env = &program.env,
        .definitions = program.definitions,
        .indices = .init(scratch.allocator()),
        .seen = try scratch.allocator().alloc(bool, program.definitions.len),
    };
    @memset(reached.seen, false);
    for (program.definitions, 0..) |d, i| try reached.indices.put(d.symbol, @intCast(i));
    _ = try reached.visit(program.entry, .use);
    while (reached.pending.pop()) |i| _ = try core.free.anyMention(program.definitions[i].body, &reached, Reached.visit);
    if (std.mem.indexOfScalar(bool, reached.seen, false) == null) return;

    const before = std.mem.count(bool, reached.seen[0..program.entry_offset], &.{true});
    const entry = std.mem.count(bool, reached.seen[program.entry_offset..program.entry_end], &.{true});
    var kept: std.ArrayList(core.Definition) = .empty;
    for (program.definitions, reached.seen) |d, seen| if (seen) try kept.append(program.env.allocator(), d);
    program.definitions = kept.items;
    program.entry_offset = @intCast(before);
    program.entry_end = @intCast(before + entry);
    program.components = &.{};
}

/// The definitions reached so far, by position.
const Reached = struct {
    scratch: Allocator,
    env: *const core.env.Env,
    definitions: []const core.Definition,
    /// Each definition's position.
    indices: core.SymbolTable(u32),
    seen: []bool,
    /// Reached, with bodies not yet walked.
    pending: std.ArrayList(u32) = .empty,

    fn visit(self: *Reached, symbol: core.SymbolId, role: core.free.Role) Error!bool {
        if (role != .use) return false;
        for (laws.selectable(&self.env.interner, &self.env.classes, symbol)) |method| _ = try self.visit(method, .use);
        const i = self.indices.get(symbol) orelse return false;
        if (self.seen[i]) return false;
        self.seen[i] = true;
        try self.pending.append(self.scratch, i);
        return false;
    }
};

/// Substitute constant dictionaries. Returns whether one was.
fn substitute(program: *core.Program, options: Options) Error!bool {
    if (!options.dictionary_arguments) return false;
    var scratch: std.heap.ArenaAllocator = .init(program.env.gpa);
    defer scratch.deinit();
    var substituter: dictionaries.Substituter = .init(scratch.allocator(), .{ .allocator = program.env.allocator() }, &program.env);
    return try substituter.run(program);
}

/// Panic if `program` breaks an invariant on join points.
fn expectJoinPointsHold(program: *const core.Program) Error!void {
    const violation = try core.lint.program(program.env.gpa, program) orelse return;
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    violation.write(&program.env.interner, &w) catch {};
    std.debug.panic("core_to_core: {s}", .{w.buffered()});
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
        .contify = options.contification,
    };
    const analysis = try analyser.program(program.definitions);
    var simplifier: Simplifier = .init(&analyser, &program.env, options, phase);

    for (analysis.definitions) |d| try simplifier.seed(d.symbol, d.body);
    const simplified = try builder.slice(core.Definition, program.definitions.len);
    for (analysis.order) |i| {
        const old = analysis.definitions[i];
        const body = try simplifier.simplify(old.body);
        simplified[i] = .{ .symbol = old.symbol, .body = body, .span = old.span };
        try simplifier.unfold(old.symbol, body);
        try simplifier.know(old.symbol, body);
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
    const class = try e.classes.declare(.{ .name = .{ .module = .prim, .name = "Describe" } });
    const describe = try e.interner.intern(.prim, "describe", .{ .method = .{ .class = class, .index = 0 } });
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
