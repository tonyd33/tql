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
        /// binder or the parameters of a join point that is not recursive.
        /// Never set for a join point.
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

/// How a term uses one binder.
const Use = struct {
    /// `once` or `many`.
    occurrence: Occurrence,
    /// The number of arguments every occurrence is applied to, when every
    /// one heads a call in tail position. Null otherwise.
    tail_calls: ?u32,

    fn insideLambda(self: Use) Use {
        return .{ .occurrence = self.occurrence.insideLambda(), .tail_calls = null };
    }
};

/// Each free local, and each definition while a program is analysed, that a
/// term mentions.
const Usage = std.AutoArrayHashMapUnmanaged(core.SymbolId, Use);

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
/// - a `let` or `letrec` binder whose every occurrence is a call of one
///   arity in tail position, and whose value opens with that many lambdas,
///   becomes a join point. A recursive group's binders all do, or none;
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
    /// Its interner receives each binder's join point flag.
    env: *core.env.Env,
    table: *Table,
    /// Drop a dead `let` and a recursive group nothing live mentions.
    drop_dead: bool = true,
    /// Make join points of binders that are not yet.
    contify: bool = true,
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
            .symbol, .apply => return try self.spine(term, 0),
            .lambda => {
                var analysed = try self.walkLambdas(term, term.arity());
                for (analysed.usage.values()) |*use| use.* = use.insideLambda();
                return analysed;
            },
            .case => |case_term| {
                var scrutinee = try self.walk(case_term.scrutinee);
                notTail(&scrutinee.usage);
                var branches: Usage = .empty;
                const alternatives = try self.builder.slice(core.Case.Alternative, case_term.alternatives.len);
                for (case_term.alternatives, alternatives) |old, *new| {
                    var body = try self.walk(old.body);
                    for (old.binders) |binder| try self.bind(&body.usage, binder);
                    branches = try self.alternative(branches, body.usage);
                    new.* = .{ .constructor = old.constructor, .binders = old.binders, .body = body.term };
                }
                var default: ?core.Term = null;
                if (case_term.default) |old| {
                    const body = try self.walk(old);
                    branches = try self.alternative(branches, body.usage);
                    default = body.term;
                }
                return .{
                    .term = try self.builder.caseWithDefault(scrutinee.term, alternatives, default, term.span),
                    .usage = try self.sequence(scrutinee.usage, branches),
                };
            },
            .let => |let| {
                var body = try self.walk(let.body);
                if (self.drop_dead and !body.usage.contains(let.name)) return body;
                const arity = self.letArity(let.name, let.value, body.usage);
                self.flag(let.name, arity);
                var value = try self.walkLambdas(let.value, arity orelse 0);
                if (arity == null) notTail(&value.usage);
                try self.bind(&body.usage, let.name);
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

        // Each value is walked under the lambdas it would take as a join
        // point, until its binding is decided.
        const values = try self.scratch.alloc(Analysed, letrec.bindings.len);
        const names = try self.scratch.alloc(core.SymbolId, letrec.bindings.len);
        const arities = try self.scratch.alloc(?u32, letrec.bindings.len);
        for (letrec.bindings, values, names, arities) |binding, *value, *name, *arity| {
            arity.* = self.candidate(binding.name, binding.value);
            value.* = try self.walkLambdas(binding.value, arity.* orelse 0);
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
            const live = !self.drop_dead or for (members) |member| {
                if (usage.contains(letrec.bindings[member].name)) break true;
            } else false;
            if (!live) continue;

            const joins = self.decide(members, names, arities, usage, values);
            if (!core.components.cyclic(members, edges)) {
                const member = members[0];
                if (!joins) escape(&values[member].usage, arities[member] orelse 0);
                try self.bind(&usage, names[member]);
                usage = try self.sequence(usage, values[member].usage);
                result = try self.builder.let(names[member], values[member].term, result, span);
                continue;
            }

            for (members) |member| {
                // Count a recursive join point's value as under a lambda,
                // keeping its tail calls.
                if (joins) {
                    for (values[member].usage.values()) |*use| use.occurrence = use.occurrence.insideLambda();
                } else escape(&values[member].usage, arities[member] orelse 0);
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

    /// Walk `term`, the function of an application spine with `arguments`
    /// arguments after it.
    fn spine(self: *Analyser, term: core.Term, arguments: u32) Allocator.Error!Analysed {
        switch (term.kind) {
            .apply => |apply| {
                const function = try self.spine(apply.function, arguments + 1);
                var argument = try self.walk(apply.argument);
                notTail(&argument.usage);
                return .{
                    .term = try self.builder.apply(function.term, argument.term, term.span),
                    .usage = try self.sequence(function.usage, argument.usage),
                };
            },
            .symbol => |id| {
                var usage: Usage = .empty;
                const definition = if (self.definitions) |definitions| definitions.get(id) != null else false;
                if (definition or !self.env.interner.isGlobal(id)) {
                    try usage.put(self.scratch, id, .{
                        .occurrence = .{ .once = .{ .inside_lambda = false, .branches = 1 } },
                        .tail_calls = arguments,
                    });
                }
                return .{ .term = term, .usage = usage };
            },
            else => {
                var head = try self.walk(term);
                notTail(&head.usage);
                return head;
            },
        }
    }

    /// Walk `term` under its first `count` lambdas, binding their parameters.
    /// Occurrences under them are not marked inside a lambda.
    fn walkLambdas(self: *Analyser, term: core.Term, count: usize) Allocator.Error!Analysed {
        if (count == 0) return try self.walk(term);
        const lambda = term.kind.lambda;
        var body = try self.walkLambdas(lambda.body, count - 1);
        try self.bind(&body.usage, lambda.parameter);
        return .{ .term = try self.builder.lambda(lambda.parameter, body.term, term.span), .usage = body.usage };
    }

    /// The join arity of `name`, bound by a `let` to `value` over a body used
    /// as `usage` says, or null when it is not a join point: the number of
    /// arguments every occurrence is tail-called with, when that is its
    /// arity already, or it may become one and `value` has as many lambdas.
    /// A binder with no occurrence keeps its arity.
    fn letArity(self: *const Analyser, name: core.SymbolId, value: core.Term, usage: Usage) ?u32 {
        const details = self.env.interner.details(name);
        const use = usage.get(name) orelse return details.joinArity();
        const arity = use.tail_calls orelse return null;
        return switch (details) {
            .join => |join| if (join.arity == arity) arity else null,
            .vanilla => if (self.contify and arity <= value.arity()) arity else null,
            else => null,
        };
    }

    /// The arity `name`, bound by a `letrec` to `value`, has as a join point:
    /// its own if it is one, otherwise `value`'s lambdas. Null when it may not
    /// become one.
    fn candidate(self: *const Analyser, name: core.SymbolId, value: core.Term) ?u32 {
        return switch (self.env.interner.details(name)) {
            .join => |join| join.arity,
            .vanilla => if (self.contify) @intCast(value.arity()) else null,
            else => null,
        };
    }

    /// Make every member of a recursive group a join point of its arity, or
    /// none of them, and return which. `members` index `names`, `arities` and
    /// `values`. All do when each has an arity and its every occurrence in
    /// `usage` and the members' values heads a tail call of that arity. A
    /// binder with no occurrence keeps its flag.
    fn decide(
        self: *Analyser,
        members: []const u32,
        names: []const core.SymbolId,
        arities: []const ?u32,
        usage: Usage,
        values: []const Analysed,
    ) bool {
        const joins = for (members) |member| {
            const arity = arities[member] orelse break false;
            var called: ?bool = tailCalled(names[member], arity, usage);
            for (members) |other| {
                const in_value = tailCalled(names[member], arity, values[other].usage) orelse continue;
                called = in_value and (called orelse true);
            }
            if (!(called orelse (self.env.interner.details(names[member]) == .join))) break false;
        } else true;
        for (members) |member| self.flag(names[member], if (joins) arities[member] else null);
        return joins;
    }

    /// Make `name` a join point of `arity`, or not one when `arity` is null.
    fn flag(self: *Analyser, name: core.SymbolId, arity: ?u32) void {
        switch (self.env.interner.details(name)) {
            .vanilla, .join => self.env.interner.setDetails(name, if (arity) |n| .{ .join = .{ .arity = n } } else .vanilla),
            else => {},
        }
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
    /// is made a loop breaker first. An instance's dictionary ranks above the
    /// methods it holds.
    fn breakerScore(self: *const Analyser, name: core.SymbolId, value: core.Term) u8 {
        if (self.env.alwaysInlines(name)) return 3;
        if (cost.trivial(value) or self.env.interner.details(name) == .instance) return 2;
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
        var occurrence: Occurrence = if (usage.fetchSwapRemove(binder)) |entry| entry.value.occurrence else .dead;
        if (self.env.interner.details(binder) == .join) switch (occurrence) {
            .once => |*once| once.inside_lambda = false,
            else => {},
        };
        try self.table.put(binder, occurrence);
    }

    /// The usage of two terms that may both be evaluated.
    fn sequence(self: *Analyser, a: Usage, b: Usage) Allocator.Error!Usage {
        var into, const from = if (a.count() >= b.count()) .{ a, b } else .{ b, a };
        var it = from.iterator();
        while (it.next()) |entry| {
            const slot = try into.getOrPut(self.scratch, entry.key_ptr.*);
            slot.value_ptr.* = if (slot.found_existing) .{
                .occurrence = .many,
                .tail_calls = agree(slot.value_ptr.tail_calls, entry.value_ptr.tail_calls),
            } else entry.value_ptr.*;
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
            const left = slot.value_ptr.*;
            const right = entry.value_ptr.*;
            slot.value_ptr.* = .{
                .occurrence = switch (left.occurrence) {
                    .once => |left_once| switch (right.occurrence) {
                        .once => |right_once| .{ .once = .{
                            .inside_lambda = left_once.inside_lambda or right_once.inside_lambda,
                            .branches = left_once.branches + right_once.branches,
                        } },
                        else => .many,
                    },
                    else => .many,
                },
                .tail_calls = agree(left.tail_calls, right.tail_calls),
            };
        }
        return into;
    }
};

/// The arity of tail calls two usages make of one binder, when both make
/// them of the same arity.
fn agree(a: ?u32, b: ?u32) ?u32 {
    const left = a orelse return null;
    const right = b orelse return null;
    return if (left == right) left else null;
}

/// Whether every occurrence of `name` in `usage` heads a tail call of
/// `arity` arguments. Null when there is none.
fn tailCalled(name: core.SymbolId, arity: u32, usage: Usage) ?bool {
    const use = usage.get(name) orelse return null;
    return use.tail_calls == arity;
}

/// Mark every occurrence in `usage` out of tail position.
fn notTail(usage: *Usage) void {
    for (usage.values()) |*use| use.tail_calls = null;
}

/// Turn the usage of a value under its first `lambdas` lambdas into the usage
/// of the value bound by a binder that is not a join point.
fn escape(usage: *Usage, lambdas: u32) void {
    if (lambdas == 0) return notTail(usage);
    for (usage.values()) |*use| use.* = use.insideLambda();
}

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

fn expectJoin(pb: *test_support.ProgramBuilder, expected: ?u32, binder: core.SymbolId) !void {
    try testing.expectEqual(expected, pb.env.interner.details(binder).joinArity());
}

test "mutually recursive functions become join points together or not at all" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const even = try pb.local("even");
    const odd = try pb.local("odd");
    const n = try pb.local("n");
    const m = try pb.local("m");
    const h = try pb.global("h");

    // `odd` calls `even` in tail position, `even` calls `odd` in an argument.
    const even_value = try pb.lambda(&.{n}, try pb.apply(pb.symbol(h), &.{try pb.apply(pb.symbol(odd), &.{pb.symbol(n)})}));
    const odd_value = try pb.lambda(&.{m}, try pb.apply(pb.symbol(even), &.{pb.symbol(m)}));
    _ = try analyseTerm(&pb, &table, try pb.letrec(&.{
        .{ .name = even, .value = even_value },
        .{ .name = odd, .value = odd_value },
    }, try pb.apply(pb.symbol(even), &.{pb.number(1)})));
    try expectJoin(&pb, null, even);
    try expectJoin(&pb, null, odd);
}

test "a join point no longer called in tail position becomes a function again" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const j = try pb.join("j", 1);
    const h = try pb.global("h");

    const body = try pb.apply(pb.symbol(h), &.{try pb.apply(pb.symbol(j), &.{pb.number(1)})});
    _ = try analyseTerm(&pb, &table, try pb.let(j, try caller(&pb, h), body));
    try expectJoin(&pb, null, j);
}
