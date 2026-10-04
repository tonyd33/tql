//! Occurrence analysis: how often, and where, each local binder is used.
//!
//! Every binder is a unique symbol, so the table needs no scopes.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");

const Allocator = std.mem.Allocator;

pub const Occurrence = union(enum) {
    dead,
    once: Once,
    many,
    /// A member of a recursive group.
    loop_breaker,

    pub const Once = struct {
        /// Under a lambda that does not bind the binder itself.
        inside_lambda: bool,
        /// How many alternatives of one `case` hold an occurrence.
        branches: u32,
    };
};

pub const Table = core.SymbolTable(Occurrence);

/// Each free local a term mentions, as `once` or `many`.
const Usage = std.AutoArrayHashMapUnmanaged(core.SymbolId, Occurrence);

const Analysed = struct {
    term: core.Term,
    usage: Usage,
};

/// Record an occurrence for every local binder in the terms it walks, and
/// rebuild them:
///
/// - a `let` whose binder is dead is dropped, its value unwalked;
/// - a `letrec` is split into strongly connected components, a component
///   nothing live mentions is dropped, and one binding that does not mention
///   itself becomes a `let`.
pub const Analyser = struct {
    /// Usage maps and edge lists.
    scratch: Allocator,
    builder: core.Builder,
    interner: *const core.Interner,
    table: *Table,

    pub fn analyse(self: *Analyser, term: core.Term) Allocator.Error!core.Term {
        return (try self.walk(term)).term;
    }

    fn walk(self: *Analyser, term: core.Term) Allocator.Error!Analysed {
        switch (term.kind) {
            .literal => return .{ .term = term, .usage = .empty },
            .symbol => |id| {
                var usage: Usage = .empty;
                if (!self.interner.isGlobal(id)) {
                    try usage.put(self.scratch, id, .{ .once = .{ .inside_lambda = false, .branches = 1 } });
                }
                return .{ .term = term, .usage = usage };
            },
            .lambda => |lambda| {
                var body = try self.walk(lambda.body);
                try self.bind(&body.usage, lambda.parameter);
                for (body.usage.values()) |*occurrence| switch (occurrence.*) {
                    .once => |*once| once.inside_lambda = true,
                    else => {},
                };
                return .{
                    .term = try self.builder.lambda(lambda.parameter, body.term, term.span),
                    .usage = body.usage,
                };
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
        for (letrec.bindings, values) |binding, *value| value.* = try self.walk(binding.value);

        const edges = try self.scratch.alloc([]const u32, letrec.bindings.len);
        for (values, edges) |value, *edge| {
            var targets: std.ArrayList(u32) = .empty;
            for (letrec.bindings, 0..) |binding, j| {
                if (value.usage.contains(binding.name)) try targets.append(self.scratch, @intCast(j));
            }
            edge.* = targets.items;
        }

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

            const recursive = members.len > 1 or
                std.mem.indexOfScalar(u32, edges[members[0]], members[0]) != null;
            if (!recursive) {
                const binding = letrec.bindings[members[0]];
                try self.bind(&usage, binding.name);
                usage = try self.sequence(usage, values[members[0]].usage);
                result = try self.builder.let(binding.name, values[members[0]].term, result, span);
                continue;
            }

            const bindings = try self.builder.slice(core.Letrec.Binding, members.len);
            for (members, bindings) |member, *binding| {
                binding.* = .{ .name = letrec.bindings[member].name, .value = values[member].term };
                usage = try self.sequence(usage, values[member].usage);
            }
            for (bindings) |binding| {
                _ = usage.swapRemove(binding.name);
                try self.table.put(binding.name, .loop_breaker);
            }
            result = try self.builder.letrec(bindings, result, span);
        }
        return .{ .term = result, .usage = usage };
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
        .interner = &pb.env.interner,
        .table = table,
    };
    return try analyser.analyse(t);
}

fn expectPrints(pb: *const test_support.ProgramBuilder, expected: []const u8, t: core.Term) !void {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    const printer: core.Printer = .{ .interner = &pb.env.interner };
    try printer.term(t, &w.writer);
    try testing.expectEqualStrings(expected, w.written());
}

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

test "an occurrence under an inner lambda is inside a lambda" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    var table: Table = .init(testing.allocator);
    defer table.deinit();
    const x = try pb.local("x");
    const y = try pb.local("y");

    _ = try analyseTerm(&pb, &table, try pb.lambda(&.{ x, y }, pb.symbol(x)));
    try testing.expectEqual(Occurrence{ .once = .{ .inside_lambda = true, .branches = 1 } }, table.get(x).?);
    try testing.expectEqual(Occurrence.dead, table.get(y).?);
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
