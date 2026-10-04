//! Occurrence analysis: how often, and where, each binder is used, and which
//! bindings break the cycles of recursive groups.
//!
//! Every binder is a unique symbol, so the table needs no scopes.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const cost = @import("cost.zig");

const Allocator = std.mem.Allocator;

pub const Occurrence = union(enum) {
    dead,
    once: Once,
    many,
    /// A member of a recursive group, chosen so that every cycle passes
    /// through one. Never inlined.
    loop_breaker,

    pub const Once = struct {
        /// Under a lambda, not counting the chain of lambdas that binds the
        /// binder.
        inside_lambda: bool,
        /// How many alternatives of one `case` hold an occurrence.
        branches: u32,
    };

    /// The occurrence as seen from outside a lambda around it.
    pub fn insideLambda(self: Occurrence) Occurrence {
        return switch (self) {
            .once => |once| .{ .once = .{ .inside_lambda = true, .branches = once.branches } },
            else => self,
        };
    }
};

pub const Table = core.SymbolTable(Occurrence);

/// Each free local, and each definition while a program is analysed, that a
/// term mentions, as `once` or `many`.
const Usage = std.AutoArrayHashMapUnmanaged(core.SymbolId, Occurrence);

const Analysed = struct {
    term: core.Term,
    usage: Usage,
};

/// A linked program's definitions, analysed.
pub const Analysis = struct {
    definitions: []core.Definition,
    /// Indices into `definitions`, each after the definitions it references
    /// other than loop breakers.
    order: []const u32,
};

/// Record an occurrence for every binder in the terms it walks, and rebuild
/// them:
///
/// - a `let` whose binder is dead is dropped, its value unwalked;
/// - a `letrec` is split into strongly connected components, a component
///   nothing live mentions is dropped, and one binding that does not mention
///   itself becomes a `let`;
/// - a cyclic component gets loop breakers, and lists its members after the
///   non-breakers they reference.
pub const Analyser = struct {
    /// Usage maps and edge lists.
    scratch: Allocator,
    builder: core.Builder,
    env: *const core.env.Env,
    table: *Table,
    /// The program's definitions, while a program is analysed.
    definitions: ?*const core.SymbolTable(void) = null,

    pub fn analyse(self: *Analyser, term: core.Term) Allocator.Error!core.Term {
        return (try self.walk(term)).term;
    }

    /// Analyse every definition as one recursive group, every member live.
    pub fn program(self: *Analyser, definitions: []const core.Definition) Allocator.Error!Analysis {
        var members = core.SymbolTable(void).init(self.scratch);
        for (definitions) |definition| try members.put(definition.symbol, {});
        self.definitions = &members;
        defer self.definitions = null;

        const analysed = try self.builder.slice(core.Definition, definitions.len);
        const values = try self.scratch.alloc(Analysed, definitions.len);
        const names = try self.scratch.alloc(core.SymbolId, definitions.len);
        for (definitions, analysed, values, names) |old, *new, *value, *name| {
            value.* = try self.walk(old.body);
            new.* = .{ .symbol = old.symbol, .body = value.term, .span = old.span };
            name.* = old.symbol;
        }

        const all = try self.scratch.alloc(u32, definitions.len);
        for (all, 0..) |*index, i| index.* = @intCast(i);
        const cut = try self.breakCycles(all, try self.mentions(names, values), names, values);

        var usage: Usage = .empty;
        for (values) |value| usage = try self.sequence(usage, value.usage);
        for (names, cut.breakers) |name, breaker| try self.record(&usage, name, breaker);
        return .{ .definitions = analysed, .order = cut.order };
    }

    fn walk(self: *Analyser, term: core.Term) Allocator.Error!Analysed {
        switch (term.kind) {
            .literal => return .{ .term = term, .usage = .empty },
            .symbol => |id| {
                var usage: Usage = .empty;
                const definition = if (self.definitions) |definitions| definitions.get(id) != null else false;
                if (definition or !self.env.interner.isGlobal(id)) {
                    try usage.put(self.scratch, id, .{ .once = .{ .inside_lambda = false, .branches = 1 } });
                }
                return .{ .term = term, .usage = usage };
            },
            .lambda => {
                var chain: std.ArrayList(core.Term) = .empty;
                var inner = term;
                while (inner.kind == .lambda) : (inner = inner.kind.lambda.body) {
                    try chain.append(self.scratch, inner);
                }
                var body = try self.walk(inner);
                for (chain.items) |lambda| try self.bind(&body.usage, lambda.kind.lambda.parameter);
                for (body.usage.values()) |*occurrence| occurrence.* = occurrence.insideLambda();
                var result = body.term;
                var i = chain.items.len;
                while (i > 0) {
                    i -= 1;
                    const lambda = chain.items[i];
                    result = try self.builder.lambda(lambda.kind.lambda.parameter, result, lambda.span);
                }
                return .{ .term = result, .usage = body.usage };
            },
            .apply => |apply| {
                const function = try self.walk(apply.function);
                const argument = try self.walk(apply.argument);
                return .{
                    .term = try self.builder.apply(function.term, argument.term, term.span),
                    .usage = try self.sequence(function.usage, argument.usage),
                };
            },
            .case => |case_term| {
                const scrutinee = try self.walk(case_term.scrutinee);
                var branches: Usage = .empty;
                const alternatives = try self.builder.slice(core.Case.Alternative, case_term.alternatives.len);
                for (case_term.alternatives, alternatives) |old, *new| {
                    var body = try self.walk(old.body);
                    for (old.binders) |binder| try self.bind(&body.usage, binder);
                    branches = try self.alternative(branches, body.usage);
                    new.* = .{ .constructor = old.constructor, .binders = old.binders, .body = body.term };
                }
                return .{
                    .term = try self.builder.case(scrutinee.term, alternatives, term.span),
                    .usage = try self.sequence(scrutinee.usage, branches),
                };
            },
            .let => |let| {
                var body = try self.walk(let.body);
                if (!body.usage.contains(let.name)) return body;
                try self.bind(&body.usage, let.name);
                const value = try self.walk(let.value);
                return .{
                    .term = try self.builder.let(let.name, value.term, body.term, term.span),
                    .usage = try self.sequence(body.usage, value.usage),
                };
            },
            .letrec => |letrec| return try self.group(letrec, term.span),
        }
    }

    fn group(self: *Analyser, letrec: *const core.Letrec, span: diagnostic.Span) Allocator.Error!Analysed {
        const body = try self.walk(letrec.body);

        const values = try self.scratch.alloc(Analysed, letrec.bindings.len);
        const names = try self.scratch.alloc(core.SymbolId, letrec.bindings.len);
        for (letrec.bindings, values, names) |binding, *value, *name| {
            value.* = try self.walk(binding.value);
            name.* = binding.name;
        }

        const edges = try self.mentions(names, values);
        var found = try core.components.stronglyConnectedComponents(self.scratch, edges);
        defer found.deinit();

        var usage = body.usage;
        var result = body.term;
        var i = found.groups.len;
        while (i > 0) {
            i -= 1;
            const members = found.groups[i];
            const live = for (members) |member| {
                if (usage.contains(letrec.bindings[member].name)) break true;
            } else false;
            if (!live) continue;

            if (!core.components.cyclic(members, edges)) {
                const binding = letrec.bindings[members[0]];
                try self.bind(&usage, binding.name);
                usage = try self.sequence(usage, values[members[0]].usage);
                result = try self.builder.let(binding.name, values[members[0]].term, result, span);
                continue;
            }

            const cut = try self.breakCycles(members, edges, names, values);
            for (members) |member| usage = try self.sequence(usage, values[member].usage);

            const bindings = try self.builder.slice(core.Letrec.Binding, members.len);
            for (cut.order, bindings) |member, *binding| {
                binding.* = .{ .name = names[member], .value = values[member].term };
                try self.record(&usage, names[member], cut.breakers[member]);
            }
            result = try self.builder.letrec(bindings, result, span);
        }
        return .{ .term = result, .usage = usage };
    }

    /// For each binding, by index into `names`, the indices of the bindings
    /// its value mentions.
    fn mentions(self: *Analyser, names: []const core.SymbolId, values: []const Analysed) Allocator.Error![]const []const u32 {
        const result = try self.scratch.alloc([]const u32, names.len);
        for (values, result) |value, *targets| {
            var mentioned: std.ArrayList(u32) = .empty;
            for (names, 0..) |name, j| {
                if (value.usage.contains(name)) try mentioned.append(self.scratch, @intCast(j));
            }
            targets.* = mentioned.items;
        }
        return result;
    }

    const Cut = struct {
        /// Indexed like `names`.
        breakers: []const bool,
        /// `members`, each after the members it mentions other than breakers.
        order: []const u32,
    };

    /// Choose loop breakers among `members`, indices into `names`, so that
    /// every cycle of `edges` through them passes through one.
    fn breakCycles(
        self: *Analyser,
        members: []const u32,
        edges: []const []const u32,
        names: []const core.SymbolId,
        values: []const Analysed,
    ) Allocator.Error!Cut {
        const scores = try self.scratch.alloc(u8, names.len);
        for (names, values, scores) |name, value, *score| score.* = self.breakerScore(name, value.term);
        const breakers = try self.scratch.alloc(bool, names.len);
        @memset(breakers, false);
        try self.cutCycles(members, edges, scores, breakers);
        return .{ .breakers = breakers, .order = try self.dependencyOrder(members, edges, breakers) };
    }

    /// Mark the lowest-scoring member of each cycle of `edges` among
    /// `members` a breaker, then do the same for what is still cyclic.
    fn cutCycles(
        self: *Analyser,
        members: []const u32,
        edges: []const []const u32,
        scores: []const u8,
        breakers: []bool,
    ) Allocator.Error!void {
        const sub = try self.subgraph(members, edges, breakers);
        var found = try core.components.stronglyConnectedComponents(self.scratch, sub);
        defer found.deinit();

        for (found.groups) |component| {
            if (!core.components.cyclic(component, sub)) continue;
            var best = members[component[0]];
            for (component[1..]) |position| {
                if (scores[members[position]] < scores[best]) best = members[position];
            }
            breakers[best] = true;

            const rest = try self.scratch.alloc(u32, component.len - 1);
            var i: usize = 0;
            for (component) |position| {
                if (members[position] == best) continue;
                rest[i] = members[position];
                i += 1;
            }
            try self.cutCycles(rest, edges, scores, breakers);
        }
    }

    /// `members`, each after the members it references other than breakers.
    fn dependencyOrder(
        self: *Analyser,
        members: []const u32,
        edges: []const []const u32,
        breakers: []const bool,
    ) Allocator.Error![]const u32 {
        const sub = try self.subgraph(members, edges, breakers);
        var found = try core.components.stronglyConnectedComponents(self.scratch, sub);
        defer found.deinit();

        const ordered = try self.scratch.alloc(u32, members.len);
        var i: usize = 0;
        for (found.groups) |component| {
            for (component) |position| {
                ordered[i] = members[position];
                i += 1;
            }
        }
        return ordered;
    }

    /// The edges among `members`, by position in `members`, without the edges
    /// into breakers.
    fn subgraph(
        self: *Analyser,
        members: []const u32,
        edges: []const []const u32,
        breakers: []const bool,
    ) Allocator.Error![]const []const u32 {
        const sub = try self.scratch.alloc([]const u32, members.len);
        for (members, sub) |member, *targets| {
            var kept: std.ArrayList(u32) = .empty;
            for (edges[member]) |target| {
                if (breakers[target]) continue;
                const position = std.mem.indexOfScalar(u32, members, target) orelse continue;
                try kept.append(self.scratch, @intCast(position));
            }
            targets.* = kept.items;
        }
        return sub;
    }

    /// How much inlining a binding of `name` to `value` is worth. The lowest
    /// is made a loop breaker first.
    fn breakerScore(self: *const Analyser, name: core.SymbolId, value: core.Term) u8 {
        if (self.env.alwaysInlines(name)) return 3;
        if (cost.trivial(value)) return 2;
        if (value.kind == .lambda) return 1;
        return 0;
    }

    /// Record `binder` as a loop breaker, or by its occurrence in `usage`, and
    /// remove it from `usage`.
    fn record(self: *Analyser, usage: *Usage, binder: core.SymbolId, breaker: bool) Allocator.Error!void {
        if (!breaker) return try self.bind(usage, binder);
        _ = usage.swapRemove(binder);
        try self.table.put(binder, .loop_breaker);
    }

    /// Record `binder`'s occurrence and remove it from `usage`.
    fn bind(self: *Analyser, usage: *Usage, binder: core.SymbolId) Allocator.Error!void {
        const occurrence = if (usage.fetchSwapRemove(binder)) |entry| entry.value else .dead;
        try self.table.put(binder, occurrence);
    }

    /// The usage of two terms that may both be evaluated.
    fn sequence(self: *Analyser, a: Usage, b: Usage) Allocator.Error!Usage {
        var into, const from = if (a.count() >= b.count()) .{ a, b } else .{ b, a };
        var it = from.iterator();
        while (it.next()) |entry| {
            const slot = try into.getOrPut(self.scratch, entry.key_ptr.*);
            slot.value_ptr.* = if (slot.found_existing) .many else entry.value_ptr.*;
        }
        return into;
    }

    /// The usage of two alternatives of one `case`, of which one is evaluated.
    fn alternative(self: *Analyser, a: Usage, b: Usage) Allocator.Error!Usage {
        var into, const from = if (a.count() >= b.count()) .{ a, b } else .{ b, a };
        var it = from.iterator();
        while (it.next()) |entry| {
            const slot = try into.getOrPut(self.scratch, entry.key_ptr.*);
            if (!slot.found_existing) {
                slot.value_ptr.* = entry.value_ptr.*;
                continue;
            }
            slot.value_ptr.* = switch (slot.value_ptr.*) {
                .once => |left| switch (entry.value_ptr.*) {
                    .once => |right| .{ .once = .{
                        .inside_lambda = left.inside_lambda or right.inside_lambda,
                        .branches = left.branches + right.branches,
                    } },
                    else => .many,
                },
                else => .many,
            };
        }
        return into;
    }
};

const testing = std.testing;
const test_support = core.test_support;

/// Analyse `t` into `table` and return it rebuilt.
fn analyseTerm(pb: *test_support.ProgramBuilder, table: *Table, t: core.Term) !core.Term {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var analyser: Analyser = .{
        .scratch = scratch.allocator(),
        .builder = pb.terms(),
        .env = &pb.env,
        .table = table,
    };
    return try analyser.analyse(t);
}

const expectPrints = test_support.expectPrints;

test "a binder used once outside any lambda is once in one branch" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const f = try pb.global("f");
    const x = try pb.local("x");

    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{x}, try pb.apply(pb.symbol(f), &.{pb.symbol(x)})));
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = false, .branches = 1 } }, table.get(x).?);
}

test "an occurrence under a lambda in the body is inside a lambda" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const f = try pb.global("f");
    const x = try pb.local("x");
    const y = try pb.local("y");

    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{x}, try pb.apply(pb.symbol(f), &.{try pb.lambda(&.{y}, pb.symbol(x))})));
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = true, .branches = 1 } }, table.get(x).?);
    try testing.expectEqual(Occurrence.dead, table.get(y).?);
}

test "a chain of lambdas is one group" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const x = try pb.local("x");
    const y = try pb.local("y");

    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{ x, y }, pb.symbol(x)));
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = false, .branches = 1 } }, table.get(x).?);
}

test "occurrences in two alternatives are once in two branches" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const s = try pb.global("s");
    const x = try pb.local("x");
    const h = try pb.local("h");
    const t = try pb.local("t");

    const term = try pb.lambda(&.{x}, try pb.case(pb.symbol(s), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(x) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = pb.symbol(x) },
    }));
    _ = try analyseTerm(&pb, &table, term);
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = false, .branches = 2 } }, table.get(x).?);
    try testing.expectEqual(Occurrence.dead, table.get(h).?);
}

test "two occurrences that may both be evaluated are many" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const nil = try pb.global("Nil");
    const f = try pb.global("f");
    const x = try pb.local("x");
    const y = try pb.local("y");

    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{x}, try pb.apply(pb.symbol(f), &.{ pb.symbol(x), pb.symbol(x) })));
    try testing.expectEqual(Occurrence.many, table.get(x).?);

    // A scrutinee and one alternative.
    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{y}, try pb.case(pb.symbol(y), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(y) },
    })));
    try testing.expectEqual(Occurrence.many, table.get(y).?);
}

test "a dead let is dropped and its value's references do not count" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const f = try pb.global("f");
    const x = try pb.local("x");
    const a = try pb.local("a");

    const term = try pb.lambda(&.{x}, try pb.let(a, try pb.apply(pb.symbol(f), &.{pb.symbol(x)}), pb.number(1)));
    try expectPrints(&pb, "\\x -> 1", try analyseTerm(&pb, &table, term));
    try testing.expectEqual(Occurrence.dead, table.get(x).?);
}

test "a letrec splits into a let and a letrec of its cycle" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const cons = try pb.global("Cons");
    const a = try pb.local("a");
    const b = try pb.local("b");

    const term = try pb.letrec(&.{
        .{ .name = a, .value = pb.number(1) },
        .{ .name = b, .value = try pb.apply(pb.symbol(cons), &.{ pb.symbol(a), pb.symbol(b) }) },
    }, pb.symbol(b));
    try expectPrints(&pb,
        \\let a = 1 in
        \\letrec b = Cons a b in
        \\b
    , try analyseTerm(&pb, &table, term));
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = false, .branches = 1 } }, table.get(a).?);
    try testing.expectEqual(Occurrence.loop_breaker, table.get(b).?);
}

test "a component nothing live mentions is dropped" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const cons = try pb.global("Cons");
    const x = try pb.local("x");
    const a = try pb.local("a");
    const b = try pb.local("b");
    const c = try pb.local("c");

    const term = try pb.lambda(&.{x}, try pb.letrec(&.{
        .{ .name = a, .value = try pb.apply(pb.symbol(cons), &.{ pb.symbol(x), pb.symbol(b) }) },
        .{ .name = b, .value = try pb.apply(pb.symbol(cons), &.{ pb.symbol(x), pb.symbol(a) }) },
        .{ .name = c, .value = pb.number(1) },
    }, pb.symbol(c)));
    try expectPrints(&pb,
        \\\x ->
        \\  let c = 1 in
        \\  c
    , try analyseTerm(&pb, &table, term));
    try testing.expectEqual(Occurrence.dead, table.get(x).?);
}

/// `\x -> f x`, calling `f` on the lambda's parameter.
fn caller(pb: *test_support.ProgramBuilder, f: core.SymbolId) !core.Term {
    const x = try pb.local("x");
    return try pb.lambda(&.{x}, try pb.apply(pb.symbol(f), &.{pb.symbol(x)}));
}

test "every cycle of a group passes through a loop breaker" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const a = try pb.local("a");
    const b = try pb.local("b");
    const c = try pb.local("c");
    const x = try pb.local("x");

    // a -> b -> c -> a, and c -> b.
    const c_value = try pb.lambda(&.{x}, try pb.apply(pb.symbol(a), &.{
        try pb.apply(pb.symbol(b), &.{pb.symbol(x)}),
    }));
    const term = try pb.letrec(&.{
        .{ .name = a, .value = try caller(&pb, b) },
        .{ .name = b, .value = try caller(&pb, c) },
        .{ .name = c, .value = c_value },
    }, pb.symbol(a));
    const analysed = try analyseTerm(&pb, &table, term);

    try testing.expectEqual(Occurrence.loop_breaker, table.get(a).?);
    try testing.expectEqual(Occurrence.loop_breaker, table.get(b).?);
    try testing.expect(table.get(c).? != .loop_breaker);

    // `c` is listed before `b`, which calls it.
    const bindings = analysed.kind.letrec.bindings;
    var c_at: usize = 0;
    var b_at: usize = 0;
    for (bindings, 0..) |binding, i| {
        if (binding.name == c) c_at = i;
        if (binding.name == b) b_at = i;
    }
    try testing.expect(c_at < b_at);
}

test "a loop breaker is not a binding marked to always inline" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const a = try pb.local("a");
    const b = try pb.local("b");
    try pb.env.markAlwaysInline(a);

    const term = try pb.letrec(&.{
        .{ .name = a, .value = try caller(&pb, b) },
        .{ .name = b, .value = try caller(&pb, a) },
    }, pb.symbol(a));
    _ = try analyseTerm(&pb, &table, term);

    try testing.expect(table.get(a).? != .loop_breaker);
    try testing.expectEqual(Occurrence.loop_breaker, table.get(b).?);
}

test "a program's definitions are recorded and ordered after their callees" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const h = try pb.global("h");

    // f -> g -> f, and h -> f.
    try pb.define(f, try caller(&pb, g));
    try pb.define(g, try caller(&pb, f));
    try pb.define(h, try caller(&pb, f));

    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var analyser: Analyser = .{
        .scratch = scratch.allocator(),
        .builder = pb.terms(),
        .env = &pb.env,
        .table = &table,
    };
    const analysis = try analyser.program(pb.definitions.items);

    try testing.expectEqual(Occurrence.loop_breaker, table.get(f).?);
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = true, .branches = 1 } }, table.get(g).?);
    try testing.expectEqual(Occurrence.dead, table.get(h).?);
    // `g` is simplified before `f`, which calls it.
    const g_at = std.mem.indexOfScalar(u32, analysis.order, 1).?;
    const f_at = std.mem.indexOfScalar(u32, analysis.order, 0).?;
    try testing.expect(g_at < f_at);
}
