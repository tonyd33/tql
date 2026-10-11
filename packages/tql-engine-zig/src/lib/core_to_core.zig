//! Core-to-Core simplification of a checked program.
//!
//! Desugared Core is written for clarity, not speed. Consider
//!
//! ```tql
//! main = do {
//!   guard True;
//!   return 1;
//! };
//! ```
//!
//! which desugars to `bind (guard True) (\_ -> return 1)`: a call to the list
//! monad's `bind`, through a dictionary, of a `guard` that builds a
//! one-element list only for `bind` to take it apart again. The simplifier
//! turns it into
//!
//! ```
//! main = \x -> Cons 1 Nil
//! ```
//!
//! by inlining `bind`, `guard` and `return`, then cleaning up after them.
//! Almost every query gets the same treatment, because the library writes
//! queries as compositions of small functions and dictionaries.
//!
//! ## What a rewrite may do
//!
//! Every rewrite here must keep the meaning of the term it rewrites, `_|_`
//! included (see Meaning in `core.zig`), and must not duplicate work (see
//! Meaning and cost). Skipping this pass therefore changes no observable
//! result, and the corpus runs every query both ways.
//!
//! The rewrites come in two kinds. Most are equations of the calculus, such
//! as beta reduction or a `case` of a known constructor, and hold for every
//! term. The laws in `laws.zig` are different: `bind (Cons e Nil) f = f e`
//! holds because of what the list monad's `bind` means, not because of how
//! Core works, so each one carries side conditions the calculus doesn't need
//! to state.
//!
//! ## Iterations
//!
//! One rewrite tends to expose another: inlining `guard True` above leaves a
//! `case True of`, which a second look takes the alternative of. So a run
//! iterates until no rewrite fires. Each iteration drops the definitions
//! `main` doesn't reach, analyses every binder's occurrences, then simplifies
//! every definition in one traversal.
//!
//! Nothing guarantees a fixed point comes quickly, though, so a run stops
//! after `max_iterations` either way. That's safe, since every iteration's
//! output means what its input did. It may just be slower than it could be.
//!
//! ## Phases
//!
//! You might wonder why there are two phases. A law matches on the names of
//! library functions, such as `bind` or `of_kind`, and inlining one of them
//! destroys what the law would have matched. Consider
//!
//! ```tql
//! main = children | of_kind :class_declaration;
//! ```
//!
//! Inline `of_kind` first and we're left with a lambda testing each child's
//! kind. Fire the law first and we get `%children_of_kind
//! :class_declaration`, which never builds the list of children at all. So
//! the first phase inlines every function except those a law matches on,
//! giving the laws their chance, and the second inlines everything.
//!
//! Within each phase, after a run, each dictionary every call of a function
//! passes the same is substituted into the function's body. That turns calls
//! through the dictionary into calls of known methods, which the next run can
//! inline, so a run follows each substitution, for a bounded number of
//! rounds.
//!
//! Runs after inference, so a rewrite may assume its input type-checked.
//!
//! ## References
//!
//! - Simon Peyton Jones and Andre Santos. "A transformation-based optimiser
//!   for Haskell". Science of Computer Programming 32(1-3), 1998, pp. 3-47.
//! - Simon Peyton Jones and Simon Marlow. "Secrets of the Glasgow Haskell
//!   Compiler inliner". Journal of Functional Programming 12(4-5), 2002,
//!   pp. 393-434.

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
