//! Type checking: Hindley-Milner inference over linked Core.

const constraints = @import("type_check/constraints.zig");
const infer = @import("type_check/infer.zig");
const schemes = @import("type_check/schemes.zig");
const substitution = @import("type_check/substitution.zig");
const unify = @import("type_check/unify.zig");

/// Why two types could not be made equal. Public because a diagnostic renders
/// it; the unifier itself is not.
pub const Mismatch = unify.Mismatch;

/// A constraint the closed table refutes, with the term that introduced it.
/// Public for the same reason: a diagnostic renders it.
pub const Violation = constraints.Violation;

/// Type-checks a linked program, writing each definition's scheme into its
/// environment and reporting through a `diagnostic.Sink`.
pub const check = infer.check;

pub const Error = infer.Error;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(constraints);
    refAllDecls(infer);
    refAllDecls(schemes);
    refAllDecls(substitution);
    refAllDecls(unify);
}

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");
const test_support = @import("core/test_support.zig");

const testing = std.testing;
const types = core.types;
const Allocator = std.mem.Allocator;
const Substitution = substitution.Substitution;

/// Every part of the checker over one environment: a substitution, an
/// undecided constraint set, and inference driven by a symbol table of
/// schemes over hand-built Core terms.
const Fixture = struct {
    env: core.env.Env,
    subst: Substitution,
    undecided: constraints.Set,
    builder: core.Builder,
    inference: infer.Inference,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try test_support.env(gpa),
            .subst = undefined,
            .undecided = constraints.Set.init(gpa),
            .builder = undefined,
            .inference = undefined,
        };
        self.subst = Substitution.init(gpa, self.env.allocator(), &self.env.datatypes);
        self.builder = .{ .allocator = self.env.allocator() };
        try self.declareFlag();
        self.inference = infer.Inference.init(
            gpa,
            &self.subst,
            &self.undecided,
            .{
                .context = self,
                .lookupFn = lookupScheme,
            },
            &self.env,
        );
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.inference.deinit();
        self.undecided.deinit();
        self.subst.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    /// The global sources, minus annotations: the scheme table `define`
    /// fills, then synthesized symbols and constructors built on demand.
    fn lookupScheme(
        context: *const anyopaque,
        subst: *Substitution,
        id: core.SymbolId,
    ) infer.Error!?types.Scheme {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (self.env.schemeOf(id)) |s| return s;
        switch (self.env.interner.details(id)) {
            .synthesized => |s| return try schemes.schemeFor(subst, s),
            else => {},
        }
        return try infer.constructorSchemeOf(subst, &self.env.datatypes, &self.env.interner, id);
    }

    fn declareFlag(self: *Fixture) !void {
        const arena = self.env.allocator();
        const constructors = try arena.dupe(core.datatypes.Constructor, &.{
            .{ .symbol = try self.env.interner.intern("Off", .vanilla), .tag = 0, .fields = &.{} },
            .{ .symbol = try self.env.interner.intern("On", .vanilla), .tag = 1, .fields = &.{} },
        });
        _ = try self.env.datatypes.declare(&self.env.interner, "Flag", 0, constructors, .{});
    }

    fn record(self: *Fixture, labels: []const []const u8, field_types: []const types.Type) !types.Type {
        const fields = try self.env.allocator().alloc(types.Type.Field, labels.len);
        for (labels, field_types, fields) |label, t, *f| {
            f.* = .{ .label = label, .type = try types.store(self.subst.arena, t) };
        }
        return .{ .record = fields };
    }

    fn expectRenders(self: *Fixture, t: types.Type, expected: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try (try self.subst.resolveDeep(t)).format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    /// Unifies, failing the test if the two types mismatch instead.
    fn expectUnifies(self: *Fixture, expected: types.Type, found: types.Type) !void {
        return switch (unify.unify(&self.subst, expected, found)) {
            .unified => {},
            .mismatch => error.TestUnexpectedResult,
        };
    }

    /// The mismatch `expected` and `found` produce, failing the test if they
    /// unify instead.
    fn mismatch(self: *Fixture, expected: types.Type, found: types.Type) !unify.Mismatch {
        return switch (unify.unify(&self.subst, expected, found)) {
            .unified => error.TestUnexpectedResult,
            .mismatch => |m| m,
        };
    }

    fn expectHolds(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expectEqual(constraints.Outcome.holds, constraints.entails(&self.subst, class, t));
    }

    fn expectRefuted(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expect(constraints.entails(&self.subst, class, t) == .fails);
    }

    fn expectDeferred(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expect(constraints.entails(&self.subst, class, t) == .deferred);
    }

    fn expectSynthesizedScheme(self: *Fixture, synthesized: core.Synthesized, expected: []const u8) !void {
        const scheme = try schemes.schemeFor(&self.subst, synthesized);
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try scheme.format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    fn define(self: *Fixture, spelling: []const u8, scheme: types.Scheme) !core.SymbolId {
        const id = try self.env.interner.intern(spelling, .vanilla);
        try self.env.setScheme(id, scheme);
        return id;
    }

    fn name(self: *Fixture, spelling: []const u8) !core.SymbolId {
        return self.env.interner.lookup(spelling) orelse
            try self.env.interner.intern(spelling, .vanilla);
    }

    /// Interns a synthesized symbol under its bracketed spelling, the way the
    /// desugarer does, and records what it was generated from.
    fn synthesize(self: *Fixture, spelling: []const u8, what: core.Synthesized) !core.SymbolId {
        return try self.env.interner.internOrGet(spelling, .{ .synthesized = what });
    }

    fn sym(self: *Fixture, id: core.SymbolId) core.Term {
        _ = self;
        return .{ .kind = .{ .symbol = id }, .span = diagnostic.Span.unknown };
    }

    fn lit(self: *Fixture, l: core.Literal) core.Term {
        _ = self;
        return .{ .kind = .{ .literal = l }, .span = diagnostic.Span.unknown };
    }

    fn regexLit(self: *Fixture, pattern: []const u8) core.Term {
        return self.lit(.{ .regex = pattern });
    }

    fn app(self: *Fixture, function: core.Term, argument: core.Term) !core.Term {
        return self.builder.apply(function, argument, diagnostic.Span.unknown);
    }

    fn lam(self: *Fixture, parameter: core.SymbolId, body: core.Term) !core.Term {
        return self.builder.lambda(parameter, body, diagnostic.Span.unknown);
    }

    /// `case c of { Off -> e; On -> t }`, alternatives in tag order.
    fn cond(self: *Fixture, c: core.Term, t: core.Term, e: core.Term) !core.Term {
        const alternatives = try self.builder.slice(core.Case.Alternative, 2);
        alternatives[0] = .{
            .constructor = self.env.interner.lookup("Off").?,
            .binders = &.{},
            .body = e,
        };
        alternatives[1] = .{
            .constructor = self.env.interner.lookup("On").?,
            .binders = &.{},
            .body = t,
        };
        return self.builder.case(c, alternatives, diagnostic.Span.unknown);
    }

    /// A nullary constructor reference.
    fn con(self: *Fixture, spelling: []const u8) core.Term {
        return self.builder.symbol(self.env.interner.lookup(spelling).?, diagnostic.Span.unknown);
    }

    fn rec(self: *Fixture, bindings: []const core.Letrec.Binding, body: core.Term) !core.Term {
        return self.builder.letrec(bindings, body, diagnostic.Span.unknown);
    }

    fn streamBind(
        self: *Fixture,
        n: core.SymbolId,
        value: core.Term,
        body: core.Term,
    ) !core.Term {
        return self.builder.bind(n, value, body, diagnostic.Span.unknown);
    }

    fn expectType(self: *Fixture, t: core.Term, expected: []const u8) !void {
        const inferred = try self.inference.term(t);
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try (try self.subst.resolveDeep(inferred)).format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    fn expectScheme(self: *Fixture, id: core.SymbolId, expected: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try self.inference.schemeOf(id).?.format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    fn expectFails(self: *Fixture, t: core.Term, category: diagnostic.Category) !void {
        try testing.expectError(error.TypeError, self.inference.term(t));
        try testing.expectEqual(category, self.inference.failure.?.category);
    }
};

// ============================================================================
//                              substitution
// ============================================================================

test "a fresh metavariable is unsolved and distinct" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    try std.testing.expect(!std.meta.eql(a, b));
    try std.testing.expectEqual(null, t.subst.lookup(a.meta));
    try std.testing.expectEqual(2, t.subst.count());
}

test "resolve follows a chain and compresses it" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const c = try t.subst.fresh();
    t.subst.bind(a.meta, b);
    t.subst.bind(b.meta, c);
    t.subst.bind(c.meta, types.int_type);

    try std.testing.expectEqual(types.int_type, t.subst.resolve(a));
    // `a` no longer points at `b`: the chain was collapsed in passing.
    try std.testing.expect(t.subst.lookup(a.meta).?.meta != b.meta);
}

test "resolve stops at an unsolved metavariable" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, b);
    try std.testing.expectEqual(b, t.subst.resolve(a));
}

test "resolve is shallow; resolveDeep rewrites children" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    t.subst.bind(a.meta, types.string_type);
    const listed = try t.subst.datatypes.list(t.subst.arena, a);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    // Shallow: the head is already a constructor, so the element stays `?0`.
    try t.subst.resolve(listed).format(&buf.writer);
    try std.testing.expectEqualStrings("[?0]", buf.written());

    buf.clearRetainingCapacity();
    try (try t.subst.resolveDeep(listed)).format(&buf.writer);
    try std.testing.expectEqualStrings("[String]", buf.written());
}

test "occurs check finds a metavariable nested in a type" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const nested = try types.func(t.subst.arena, types.int_type, try t.subst.datatypes.list(t.subst.arena, a));

    try std.testing.expect(t.subst.occurs(a.meta, nested));
    try std.testing.expect(!t.subst.occurs(b.meta, nested));
}

test "occurs check sees through a solved metavariable" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(b.meta, try t.subst.datatypes.list(t.subst.arena, a));

    // `a` is not syntactically in `b`, but it is once `b` is resolved.
    try std.testing.expect(t.subst.occurs(a.meta, b));
}

test "free metavariables are collected once, in first-seen order" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const both = try types.func(t.subst.arena, a, try types.func(t.subst.arena, b, a));

    var found: std.ArrayList(types.Meta) = .empty;
    defer found.deinit(gpa);
    try t.subst.freeMetas(both, &found);

    try std.testing.expectEqualSlices(types.Meta, &.{ a.meta, b.meta }, found.items);
}

test "a solved metavariable is not free" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, types.int_type);
    const both = try types.func(t.subst.arena, a, b);

    var found: std.ArrayList(types.Meta) = .empty;
    defer found.deinit(gpa);
    try t.subst.freeMetas(both, &found);

    try std.testing.expectEqualSlices(types.Meta, &.{b.meta}, found.items);
}

test "instantiation replaces bound variables with fresh metavariables" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    // `identity :: Filter a a`, the shape `primitives.zig` writes at comptime.
    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = try t.subst.datatypes.filter(t.subst.arena, types.variable_type(0), types.variable_type(0)),
    };
    const inst = try t.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    try std.testing.expectEqualStrings("?0 -> [?0]", buf.written());
    try std.testing.expectEqual(1, inst.metas.len);
}

test "two instantiations of one scheme share nothing" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = try t.subst.datatypes.filter(t.subst.arena, types.variable_type(0), types.variable_type(0)),
    };
    const first = try t.subst.instantiate(scheme);
    const second = try t.subst.instantiate(scheme);

    t.subst.bind(first.metas[0].meta, types.int_type);
    try std.testing.expectEqual(types.int_type, t.subst.resolve(first.metas[0]));
    try std.testing.expectEqual(second.metas[0], t.subst.resolve(second.metas[0]));
}

test "instantiation leaves the source scheme untouched" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = try t.subst.datatypes.filter(t.subst.arena, types.variable_type(0), types.variable_type(0)),
    };
    const inst = try t.subst.instantiate(scheme);
    t.subst.bind(inst.metas[0].meta, types.int_type);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> [a]", buf.written());
}

test "resolveDeep rewrites through every constructor" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, types.node_type);
    t.subst.bind(b.meta, types.string_type);

    const fields = try t.env.allocator().alloc(types.Type.Field, 1);
    fields[0] = .{ .label = "k", .type = try types.store(t.subst.arena, b) };
    const shape = try types.func(t.subst.arena, a, .{ .record = fields });

    const deep = try t.subst.resolveDeep(shape);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try deep.format(&buf.writer);
    try std.testing.expectEqualStrings("Node -> {k: String}", buf.written());
}

test "quantify turns free metavariables into forall positions" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, try t.subst.datatypes.list(t.subst.arena, a));
    const scheme = try t.subst.quantify(shape, &.{a.meta}, &.{});

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> [a]", buf.written());
    try std.testing.expectEqual(1, scheme.quantified);
}

test "quantify leaves metavariables it was not given free" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, b);
    const scheme = try t.subst.quantify(shape, &.{a.meta}, &.{});

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    // `b` is still owed by an enclosing scope, so it stays a metavariable.
    try std.testing.expectEqualStrings("a -> ?1", buf.written());
}

test "quantify rewrites constraints onto the bound variables" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, types.int_type);
    const scheme = try t.subst.quantify(
        shape,
        &.{a.meta},
        &.{.{ .class = .Sized, .type = a }},
    );

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("Sized a => a -> Int", buf.written());
}

test "quantify then instantiate round-trips" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const scheme = try t.subst.quantify(try types.func(t.subst.arena, a, a), &.{a.meta}, &.{});
    const inst = try t.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    // A fresh metavariable, not the one that was quantified away.
    try std.testing.expectEqualStrings("?1 -> ?1", buf.written());
}

test "quantify resolves before binding" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, b);

    // `a` resolves to `b`, so quantifying over `b` must catch it through the
    // chain rather than only matching syntactically.
    const scheme = try t.subst.quantify(try types.func(t.subst.arena, a, b), &.{b.meta}, &.{});
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> a", buf.written());
}

// ============================================================================
//                              unify
// ============================================================================

test "identical primitives unify" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectUnifies(types.int_type, types.int_type);
}

test "different primitives do not" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(types.int_type, types.string_type);
    try testing.expectEqual(unify.Mismatch.Reason.incompatible, m.reason);
}

test "an unsolved metavariable takes the other side" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, types.node_type);
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
}

test "binding is symmetric" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(types.node_type, a);
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
}

test "a metavariable unified with itself is a no-op" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, a);
    try testing.expectEqual(null, fix.subst.lookup(a.meta));
}

test "two metavariables become one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(a, b);
    try fix.expectUnifies(b, types.string_type);

    // Solving either solves both.
    try testing.expectEqual(types.string_type, fix.subst.resolve(a));
}

test "lists unify elementwise" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(try fix.subst.datatypes.list(fix.subst.arena, a), try fix.subst.datatypes.list(fix.subst.arena, types.int_type));
    try testing.expectEqual(types.int_type, fix.subst.resolve(a));
}

test "a list does not unify with its element type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    _ = try fix.mismatch(try fix.subst.datatypes.list(fix.subst.arena, types.int_type), types.int_type);
}

test "the reported mismatch is the pair that conflicted, not the outer one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(
        try fix.subst.datatypes.list(fix.subst.arena, types.int_type),
        try fix.subst.datatypes.list(fix.subst.arena, types.string_type),
    );
    // `[int]` vs `[string]` would make a reader hunt for the difference.
    try testing.expectEqual(types.int_type, m.expected);
    try testing.expectEqual(types.string_type, m.found);
}

test "arrows unify on both sides" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(
        try types.func(fix.subst.arena, a, b),
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
    try testing.expectEqual(types.string_type, fix.subst.resolve(b));
}

test "a filter is an arrow to a list, and unifies as one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(
        try fix.subst.datatypes.filter(fix.subst.arena, a, b),
        try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.string_type),
    );
    try testing.expectEqual(types.node_type, fix.subst.resolve(a));
    try testing.expectEqual(types.string_type, fix.subst.resolve(b));
}

test "a projection does not unify with a filter" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `kind :: Node -> String`, and `main` needs `Filter Node output`. This is
    // what rejects `main = kind`.
    const a = try fix.subst.fresh();
    _ = try fix.mismatch(
        comptime types.func_type(types.node_type, types.string_type),
        try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, a),
    );
}

test "records unify regardless of label order" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, a }),
        try fix.record(&.{ "n", "k" }, &.{ types.int_type, types.string_type }),
    );
    try testing.expectEqual(types.int_type, fix.subst.resolve(a));
}

test "records with different label sets do not unify" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const m = try fix.mismatch(
        try fix.record(&.{"k"}, &.{types.string_type}),
        try fix.record(&.{"other"}, &.{types.string_type}),
    );
    try testing.expectEqual(unify.Mismatch.Reason.labels, m.reason);
}

test "a wider record does not unify with a narrower one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // No width subtyping: `{k, n}` is not acceptable where `{k}` is wanted.
    const m = try fix.mismatch(
        try fix.record(&.{"k"}, &.{types.string_type}),
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, types.int_type }),
    );
    try testing.expectEqual(unify.Mismatch.Reason.labels, m.reason);
}

test "record fields unify by label, not by position" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Same labels in swapped order with mismatched types: if the unifier
    // paired positionally, this would wrongly succeed.
    _ = try fix.mismatch(
        try fix.record(&.{ "k", "n" }, &.{ types.string_type, types.int_type }),
        try fix.record(&.{ "n", "k" }, &.{ types.string_type, types.int_type }),
    );
}

test "the occurs check rejects an infinite type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const m = try fix.mismatch(a, try fix.subst.datatypes.list(fix.subst.arena, a));
    try testing.expectEqual(unify.Mismatch.Reason.occurs, m.reason);
}

test "the occurs check sees through solved metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    try fix.expectUnifies(b, try fix.subst.datatypes.list(fix.subst.arena, a));
    // `a := b` is now `a := [a]`, reachable only by resolving `b`.
    const m = try fix.mismatch(a, b);
    try testing.expectEqual(unify.Mismatch.Reason.occurs, m.reason);
}

test "unification is transitive through nested structure" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    const c = try fix.subst.fresh();

    // `a := [b]` from the argument, then `b := c` and `c := int` chain through
    // to make the argument `[int]`.
    try fix.expectUnifies(a, try fix.subst.datatypes.list(fix.subst.arena, b));
    try fix.expectUnifies(b, c);
    try fix.expectUnifies(c, types.int_type);

    try fix.expectRenders(a, "[Int]");
}

test "an arrow whose two sides force one metavariable transitively" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();

    // `(a -> b)` against `(b -> node)` forces `a := b` then `b := node`.
    try fix.expectUnifies(try types.func(fix.subst.arena, a, b), try types.func(fix.subst.arena, b, types.node_type));
    try fix.expectRenders(a, "Node");
    try fix.expectRenders(b, "Node");
}

test "a self-referential arrow is rejected as an infinite type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();

    // `(a -> [b])` against `(b -> a)`: the argument gives `a := b`, and then
    // the result asks for `b := [b]`.
    const m = try fix.mismatch(
        try types.func(fix.subst.arena, a, try fix.subst.datatypes.list(fix.subst.arena, b)),
        try types.func(fix.subst.arena, b, a),
    );
    try testing.expectEqual(unify.Mismatch.Reason.occurs, m.reason);
}

test "a solved metavariable unifies against what it was solved to" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectUnifies(a, types.int_type);
    try fix.expectUnifies(a, types.int_type);
    _ = try fix.mismatch(a, types.string_type);
}

// ============================================================================
//                              constraints
// ============================================================================

const some_span: diagnostic.Span = .{
    .start_byte = 7,
    .end_byte = 16,
    .start_point = .{ .row = 0, .column = 7 },
    .end_point = .{ .row = 0, .column = 16 },
};

test "Eq holds for the five scalars and not regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    for ([_]types.Type{
        try fix.subst.datatypes.boolType(fix.subst.arena),
        types.int_type,
        types.string_type,
        types.range_type,
        types.node_type,
    }) |t| try fix.expectHolds(.Eq, t);

    try fix.expectRefuted(.Eq, types.regex_type);
}

test "Ord holds only for int and string" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Ord, types.int_type);
    try fix.expectHolds(.Ord, types.string_type);

    try fix.expectRefuted(.Ord, types.node_type);
    try fix.expectHolds(.Eq, types.node_type);

    try fix.expectRefuted(.Ord, try fix.subst.datatypes.boolType(fix.subst.arena));
    try fix.expectRefuted(.Ord, types.range_type);
    try fix.expectRefuted(.Ord, types.regex_type);
}

test "Sized holds for string and lists, not for int" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Sized, types.string_type);
    try fix.expectHolds(.Sized, try fix.subst.datatypes.list(fix.subst.arena, types.node_type));
    try fix.expectRefuted(.Sized, types.int_type);
}

test "Sized on a list does not descend" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // A list of functions still has a length, even though the element type
    // has no constraint at all.
    const of_functions = try fix.subst.datatypes.list(
        fix.subst.arena,
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try fix.expectHolds(.Sized, of_functions);
    try fix.expectRefuted(.Serial, of_functions);
}

test "Sized on a list of an unsolved metavariable holds without deferring" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectHolds(.Sized, try fix.subst.datatypes.list(fix.subst.arena, a));
}

test "Serial holds for the five scalars and not regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    for ([_]types.Type{
        try fix.subst.datatypes.boolType(fix.subst.arena),
        types.int_type,
        types.string_type,
        types.node_type,
        types.range_type,
    }) |t| try fix.expectHolds(.Serial, t);

    try fix.expectRefuted(.Serial, types.regex_type);
}

test "structural classes descend into lists" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Eq, try fix.subst.datatypes.list(fix.subst.arena, types.int_type));
    try fix.expectRefuted(.Eq, try fix.subst.datatypes.list(fix.subst.arena, types.regex_type));
    try fix.expectHolds(.Serial, try fix.subst.datatypes.list(fix.subst.arena, try fix.subst.datatypes.list(fix.subst.arena, types.node_type)));
}

test "structural classes descend into records" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Serial, try fix.record(
        &.{ "k", "n" },
        &.{ types.string_type, types.int_type },
    ));
    try fix.expectRefuted(.Serial, try fix.record(
        &.{ "k", "bad" },
        &.{ types.string_type, types.regex_type },
    ));
}

test "Ord and Sized do not hold for records" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const r = try fix.record(&.{"n"}, &.{types.int_type});
    try fix.expectRefuted(.Ord, r);
    try fix.expectRefuted(.Sized, r);
}

test "Ord does not hold for a list even of ordered elements" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `Ord` is exactly `Int` and `String`; nothing structural joins it.
    try fix.expectRefuted(.Ord, try fix.subst.datatypes.list(fix.subst.arena, types.int_type));
}

test "a function fails every class, and a filter is a function" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const projection = try types.func(fix.subst.arena, types.node_type, types.string_type);
    const filter = try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.string_type);

    for ([_]types.TypeClassConstraint.Class{ .Eq, .Ord, .Serial, .Sized }) |class| {
        try fix.expectRefuted(class, projection);
        try fix.expectRefuted(class, filter);
    }
}

test "a container holding a function is outside Eq and Serial" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // What `errors/types/017` and `errors/output/006` assert: the element
    // type is `Node -> String`.
    const of_projections = try fix.subst.datatypes.list(
        fix.subst.arena,
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try fix.expectRefuted(.Eq, of_projections);
    try fix.expectRefuted(.Serial, of_projections);
}

test "the reported culprit is the element, not the container" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const nested = try fix.subst.datatypes.list(fix.subst.arena, try fix.subst.datatypes.list(fix.subst.arena, types.regex_type));
    const outcome = constraints.entails(&fix.subst, .Serial, nested);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try outcome.fails.format(&buf.writer);
    try testing.expectEqualStrings("Regex", buf.written());
}

test "an unsolved metavariable defers" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectDeferred(.Serial, a);
    try fix.expectDeferred(.Eq, try fix.subst.datatypes.list(fix.subst.arena, a));
}

test "deferral resolves once the metavariable is solved" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectDeferred(.Ord, a);

    fix.subst.bind(a.meta, types.int_type);
    try fix.expectHolds(.Ord, a);
}

test "a failing field beats a deferring one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    // No solution for `a` can rescue the `regex`, so the answer is failure
    // rather than deferral.
    const mixed = try fix.record(&.{ "open", "bad" }, &.{ a, types.regex_type });
    try fix.expectRefuted(.Serial, mixed);
}

test "a deferring field defers the whole when the rest hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const mixed = try fix.record(&.{ "n", "open" }, &.{ types.int_type, a });
    try fix.expectDeferred(.Serial, mixed);
}

test "require decides eagerly and stores only the undecided" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();

    try testing.expectEqual(
        null,
        try fix.undecided.require(&fix.subst, .Eq, types.int_type, some_span),
    );
    try testing.expectEqual(0, fix.undecided.all().len);

    try testing.expectEqual(
        null,
        try fix.undecided.require(&fix.subst, .Serial, a, some_span),
    );
    try testing.expectEqual(1, fix.undecided.all().len);
}

test "require reports a violation at the origin span" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const v = (try fix.undecided.require(&fix.subst, .Eq, types.regex_type, some_span)).?;
    try testing.expectEqual(some_span.start_byte, v.origin.start_byte);
    try testing.expectEqual(some_span.end_byte, v.origin.end_byte);
    try testing.expectEqual(0, fix.undecided.all().len);
}

test "a violation renders as the fixture writes it" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const v = (try fix.undecided.require(&fix.subst, .Eq, types.regex_type, some_span)).?;

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try v.format(&buf.writer);
    // `errors/types/015` asserts exactly this sentence.
    try testing.expectEqualStrings("`Eq Regex` is not satisfied.", buf.written());
}

test "recheck drops constraints that have come to hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.undecided.require(&fix.subst, .Serial, a, some_span);
    try testing.expectEqual(1, fix.undecided.all().len);

    fix.subst.bind(a.meta, types.node_type);
    try testing.expectEqual(null, try fix.undecided.recheck(&fix.subst));
    try testing.expectEqual(0, fix.undecided.all().len);
}

test "recheck reports a constraint that has become unsatisfiable" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.undecided.require(&fix.subst, .Ord, a, some_span);

    fix.subst.bind(a.meta, types.node_type);
    const v = (try fix.undecided.recheck(&fix.subst)).?;
    try testing.expectEqual(types.TypeClassConstraint.Class.Ord, v.class);
    // Still attributed to the term that raised it, not to where it was found.
    try testing.expectEqual(some_span.start_byte, v.origin.start_byte);
}

test "recheck keeps a constraint that is still undecided" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    _ = try fix.undecided.require(&fix.subst, .Serial, a, some_span);

    fix.subst.bind(a.meta, try fix.subst.datatypes.list(fix.subst.arena, b));
    try testing.expectEqual(null, try fix.undecided.recheck(&fix.subst));
    try testing.expectEqual(1, fix.undecided.all().len);
}

test "generalization takes the constraints on the quantified metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    _ = try fix.undecided.require(&fix.subst, .Sized, a, some_span);
    _ = try fix.undecided.require(&fix.subst, .Serial, b, some_span);

    var taken: std.ArrayList(constraints.Constraint) = .empty;
    defer taken.deinit(gpa);
    try fix.undecided.partitionByMetas(&fix.subst, &.{a.meta}, &taken, gpa);

    // `a`'s constraint goes into the scheme; `b`'s is still owed by the
    // enclosing scope.
    try testing.expectEqual(1, taken.items.len);
    try testing.expectEqual(types.TypeClassConstraint.Class.Sized, taken.items[0].class);
    try testing.expectEqual(1, fix.undecided.all().len);
    try testing.expectEqual(types.TypeClassConstraint.Class.Serial, fix.undecided.all()[0].class);
}

test "a constraint on a type mentioning a quantified metavariable is taken" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.undecided.require(&fix.subst, .Serial, try fix.subst.datatypes.list(fix.subst.arena, a), some_span);

    var taken: std.ArrayList(constraints.Constraint) = .empty;
    defer taken.deinit(gpa);
    try fix.undecided.partitionByMetas(&fix.subst, &.{a.meta}, &taken, gpa);

    try testing.expectEqual(1, taken.items.len);
    try testing.expectEqual(0, fix.undecided.all().len);
}

test "the length primitive's Sized constraint defers on an open input" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try testing.expectEqual(
        null,
        try fix.undecided.require(&fix.subst, .Sized, a, some_span),
    );

    fix.subst.bind(a.meta, types.string_type);
    try testing.expectEqual(null, try fix.undecided.recheck(&fix.subst));
}

// ============================================================================
//                              schemes
// ============================================================================

test "a field access filters nodes to nodes" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectSynthesizedScheme(.{ .field = .{ .name = "name", .id = 7 } }, "Node -> [Node]");
}

test "the resolved id does not change the scheme today" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Two different fields, one scheme. Narrowing node types is the change
    // that would make this test wrong on purpose.
    try fix.expectSynthesizedScheme(.{ .field = .{ .name = "name", .id = 1 } }, "Node -> [Node]");
    try fix.expectSynthesizedScheme(.{ .field = .{ .name = "body", .id = 2 } }, "Node -> [Node]");
}

test "an operator's scheme comes from the primitive table" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectSynthesizedScheme(.{ .operator = .eq }, "Eq a => a -> a -> Bool");
    try fix.expectSynthesizedScheme(.{ .operator = .lt }, "Ord a => a -> a -> Bool");
    try fix.expectSynthesizedScheme(.{ .operator = .add }, "Int -> Int -> Int");
    try fix.expectSynthesizedScheme(.{ .operator = .match }, "String -> Regex -> Bool");
}

test "a one-field schemes.record takes one field value and yields one record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectSynthesizedScheme(
        .{ .record = &.{"name"} },
        "a -> {name: a}",
    );
}

test "a two-field schemes.record takes one value per field" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectSynthesizedScheme(
        .{ .record = &.{ "kind", "name" } },
        "a -> b -> {kind: a, name: b}",
    );
}

test "a three-field schemes.record quantifies one variable per field" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemes.schemeFor(&fix.subst, .{ .record = &.{ "a", "b", "c" } });
    try testing.expectEqual(3, scheme.quantified);
}

test "an empty schemes.record takes no arguments and is an empty record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectSynthesizedScheme(.{ .record = &.{} }, "{}");
}

test "record labels keep the order the desugarer normalized them into" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Position i in the argument list is label i in the record, which is what
    // pairs `record[kind,name] p q` correctly. Unification matches records by
    // label, but the *scheme* must still pair them.
    try fix.expectSynthesizedScheme(
        .{ .record = &.{ "alpha", "beta" } },
        "a -> b -> {alpha: a, beta: b}",
    );
}

test "too many schemes.record fields is an error rather than a wrapped variable index" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, schemes.max_record_fields + 1);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    try testing.expectError(
        error.TooManyRecordFields,
        schemes.schemeFor(&fix.subst, .{ .record = labels }),
    );
}

test "a schemes.record at the field ceiling still builds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, schemes.max_record_fields);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    const scheme = try schemes.schemeFor(&fix.subst, .{ .record = labels });
    try testing.expectEqual(schemes.max_record_fields, scheme.quantified);
}

test "a schemes.record scheme instantiates to fresh metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const scheme = try schemes.schemeFor(&fix.subst, .{ .record = &.{ "k", "n" } });
    const inst = try fix.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    try testing.expectEqualStrings(
        "?0 -> ?1 -> {k: ?0, n: ?1}",
        buf.written(),
    );
}

// ============================================================================
//                              infer
// ============================================================================

test "a literal has its scalar type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectType(fix.lit(.{ .number = 1 }), "Int");
    try fix.expectType(fix.lit(.{ .string = "s" }), "String");
    try fix.expectType(fix.regexLit("r"), "Regex");
}

test "a symbol's scheme is instantiated at its use" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const identity = try fix.define("identity", .{
        .quantified = 1,
        .type = try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(0)),
    });
    try fix.expectType(fix.sym(identity), "?0 -> [?0]");
}

test "two uses of one polymorphic symbol are independent" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const identity = try fix.define("identity", .{
        .quantified = 1,
        .type = comptime types.func_type(types.variable_type(0), types.variable_type(0)),
    });

    // `identity 1` must not fix the *other* use to `int`.
    try fix.expectType(try fix.app(fix.sym(identity), fix.lit(.{ .number = 1 })), "Int");
    try fix.expectType(fix.sym(identity), "?2 -> ?2");
}

test "an unbound symbol is an unresolved name" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const missing = try fix.name("nope");
    try fix.expectFails(fix.sym(missing), .unresolved_name);
}

test "a lambda's parameter is monomorphic in its body" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const x = try fix.name("x");
    try fix.expectType(try fix.lam(x, fix.sym(x)), "?0 -> ?0");
}

test "application unifies the argument with the parameter" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    try fix.expectType(try fix.app(fix.sym(inc), fix.lit(.{ .number = 1 })), "Int");
}

test "an argument of the wrong type is a type mismatch" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    // `errors/types/001`: `double "text"`.
    try fix.expectFails(try fix.app(fix.sym(inc), fix.lit(.{ .string = "text" })), .type_mismatch);
    try testing.expectEqual(infer.Rule.t_app, fix.inference.failure.?.rule);
}

test "applying a saturated function is over-application, not a mismatch" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/011`: `inc 1 2` where `inc :: Int -> Int`. The callee
    // resolved to a non-arrow, so there is nothing left to apply.
    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    const once = try fix.app(fix.sym(inc), fix.lit(.{ .number = 1 }));
    const twice = try fix.app(once, fix.lit(.{ .number = 2 }));

    try fix.expectFails(twice, .over_application);
    try testing.expect(fix.inference.failure.?.detail == .over_application);
}

test "applying a non-function is over-application" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/012`: `n 1` where `n :: int`.
    const n = try fix.define("n", .{ .type = types.int_type });
    try fix.expectFails(try fix.app(fix.sym(n), fix.lit(.{ .number = 1 })), .over_application);
}

test "an unresolved callee unifies rather than failing" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // A callee that is still a metavariable is neither error. Applying
    // it is what *determines* that it is a function.
    const x = try fix.name("x");
    const body = try fix.app(fix.sym(x), fix.lit(.{ .number = 1 }));
    try fix.expectType(try fix.lam(x, body), "(Int -> ?1) -> ?1");
}

test "a case unifies its alternatives" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.con("On"),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectType(c, "Int");
}

test "a scrutinee that is not a declared type is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectFails(c, .type_mismatch);
    try testing.expectEqual(infer.Rule.t_case, fix.inference.failure.?.rule);
}

test "alternatives of different types are rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.con("On"),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .string = "s" }),
    );
    try fix.expectFails(c, .type_mismatch);
}

test "a letrec group generalizes and each use instantiates" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // letrec { id = \x -> x } in id
    const x = try fix.name("x");
    const id = try fix.name("id");
    const bindings = try fix.builder.slice(core.Letrec.Binding, 1);
    bindings[0] = .{ .name = id, .value = try fix.lam(x, fix.sym(x)) };

    try fix.expectType(try fix.rec(bindings, fix.sym(id)), "?2 -> ?2");
}

test "a letrec member is monomorphic while the group is checked" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // letrec { loop = \x -> loop x } in loop. The recursive use must not be
    // generalized mid-check, or the placeholder would never be constrained.
    const x = try fix.name("x");
    const loop = try fix.name("loop");
    const recursive = try fix.app(fix.sym(loop), fix.sym(x));
    const bindings = try fix.builder.slice(core.Letrec.Binding, 1);
    bindings[0] = .{ .name = loop, .value = try fix.lam(x, recursive) };

    try fix.expectType(try fix.rec(bindings, fix.sym(loop)), "?3 -> ?4");
}

test "a stream bind takes a list and yields a list" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // bind c <- children_of in pure_of c
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const pure_of = try fix.define("pure_of", .{
        .quantified = 1,
        .type = try types.func(
            fix.subst.arena,
            types.variable_type(0),
            try fix.subst.datatypes.list(fix.subst.arena, types.variable_type(0)),
        ),
    });

    const c = try fix.name("c");
    const body = try fix.app(fix.sym(pure_of), fix.sym(c));
    try fix.expectType(try fix.streamBind(c, fix.sym(children), body), "[Node]");
}

test "a stream bind over a non-list is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const n = try fix.define("n", .{ .type = types.int_type });
    const c = try fix.name("c");
    try fix.expectFails(try fix.streamBind(c, fix.sym(n), fix.sym(c)), .type_mismatch);
    try testing.expectEqual(infer.Rule.t_bind, fix.inference.failure.?.rule);
}

test "a bind body that is not a list is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // The body must produce `[b]`; a bare element is not one.
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const c = try fix.name("c");
    try fix.expectFails(try fix.streamBind(c, fix.sym(children), fix.sym(c)), .type_mismatch);
}

test "a bound name is monomorphic in the bind body" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/output/013`: `c` cannot be used at two types. Here
    // the second use forces `node` against `[?]`, which cannot hold.
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    const c = try fix.name("c");
    const sized_use = try fix.app(fix.sym(length_of), fix.sym(c));
    const b = try fix.streamBind(c, fix.sym(children), sized_use);

    // `Sized node` is refuted, and the constraint was raised at the use site.
    try fix.expectFails(b, .unsatisfied_constraint);
}

test "instantiating a constrained scheme raises the constraint at the use" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    // `Sized int` is refuted.
    const applied = try fix.app(fix.sym(length_of), fix.lit(.{ .number = 1 }));
    try fix.expectFails(applied, .unsatisfied_constraint);
}

test "a constraint on an open type defers rather than rejecting" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    // `\x -> length_of x`: `x`'s type is open, so `Sized` cannot be decided
    // yet and must not reject.
    const x = try fix.name("x");
    const body = try fix.app(fix.sym(length_of), fix.sym(x));
    try fix.expectType(try fix.lam(x, body), "?0 -> Int");
    try testing.expectEqual(1, fix.undecided.all().len);
}

test "generalization quantifies what the environment does not hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const x = try fix.name("x");
    const inferred = try fix.inference.term(try fix.lam(x, fix.sym(x)));

    const scheme = try fix.inference.generalize(inferred, diagnostic.Span.unknown);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try testing.expectEqualStrings("a -> a", buf.written());
    try testing.expectEqual(1, scheme.quantified);
}

test "generalization does not quantify a metavariable the scope still holds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Inside `\x -> ...`, `x`'s type is monomorphic and must not be
    // quantified by a generalization in the body.
    const outer = try fix.subst.fresh();
    try fix.inference.scope.push(try fix.name("x"), .{ .monomorphic = outer });

    const scheme = try fix.inference.generalize(outer, diagnostic.Span.unknown);
    try testing.expectEqual(0, scheme.quantified);
}

test "generalization carries the residual constraint into the scheme" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    const x = try fix.name("x");
    const body = try fix.app(fix.sym(length_of), fix.sym(x));
    const inferred = try fix.inference.term(try fix.lam(x, body));

    const scheme = try fix.inference.generalize(inferred, diagnostic.Span.unknown);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    // The deferred `Sized` follows the variable it constrains.
    try testing.expectEqualStrings("Sized a => a -> Int", buf.written());
}

test "a component's scheme is generalized and visible to later components" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  use = id
    const x = try fix.name("x");
    const id = try fix.name("id");
    const use = try fix.name("use");

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = use, .body = fix.sym(id), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });

    try fix.expectScheme(id, "a -> a");
    // `use` instantiated `id`'s scheme, then generalized its own.
    try fix.expectScheme(use, "a -> a");
}

test "mutually recursive definitions are one component, generalized together" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // even = \n -> odd n;  odd = \n -> even n
    const n = try fix.name("n");
    const even = try fix.name("even");
    const odd = try fix.name("odd");

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = even, .body = try fix.lam(n, try fix.app(fix.sym(odd), fix.sym(n))), .span = .unknown };
    definitions[1] = .{ .symbol = odd, .body = try fix.lam(n, try fix.app(fix.sym(even), fix.sym(n))), .span = .unknown };

    // Both in one component: each references the other, so neither can be
    // generalized before the other is checked.
    try fix.inference.program(definitions, &.{&.{ 0, 1 }});

    try fix.expectScheme(even, "a -> b");
    try fix.expectScheme(odd, "a -> b");
}

test "a definition is checked against its callee's generalized scheme" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  pair = \y -> id (id y)
    // Two uses of `id` at the same type here, but through *separate*
    // instantiations, which only works if `id` was generalized first.
    const x = try fix.name("x");
    const y = try fix.name("y");
    const id = try fix.name("id");
    const pair = try fix.name("pair");

    const inner = try fix.app(fix.sym(id), fix.sym(y));
    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = pair, .body = try fix.lam(y, try fix.app(fix.sym(id), inner)), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });
    try fix.expectScheme(pair, "a -> a");
}

test "a polymorphic callee is used at two different types" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  both = \f -> f (id 1) (id "s")
    // The payoff of generalization: one definition, two instantiations.
    const x = try fix.name("x");
    const g = try fix.name("g");
    const id = try fix.name("id");
    const both = try fix.name("both");

    const at_int = try fix.app(fix.sym(id), fix.lit(.{ .number = 1 }));
    const at_string = try fix.app(fix.sym(id), fix.lit(.{ .string = "s" }));
    const applied = try fix.app(try fix.app(fix.sym(g), at_int), at_string);

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = both, .body = try fix.lam(g, applied), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });
    try fix.expectScheme(both, "(Int -> String -> a) -> a");
}

test "a component member that does not typecheck fails the walk" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    const bad = try fix.name("bad");

    const definitions = try fix.builder.slice(core.Definition, 1);
    definitions[0] = .{
        .symbol = bad,
        .body = try fix.app(fix.sym(inc), fix.lit(.{ .string = "s" })),
        .span = .unknown,
    };

    try testing.expectError(
        error.TypeError,
        fix.inference.program(definitions, &.{&.{0}}),
    );
    try testing.expectEqual(diagnostic.Category.type_mismatch, fix.inference.failure.?.category);
}

test "a recursive definition stays monomorphic within its own component" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // loop = \x -> loop x. The self-reference must see the placeholder, not
    // a scheme, or the recursion would generalize before it is constrained.
    const x = try fix.name("x");
    const loop = try fix.name("loop");

    const definitions = try fix.builder.slice(core.Definition, 1);
    definitions[0] = .{
        .symbol = loop,
        .body = try fix.lam(x, try fix.app(fix.sym(loop), fix.sym(x))),
        .span = .unknown,
    };

    try fix.inference.program(definitions, &.{&.{0}});
    try fix.expectScheme(loop, "a -> b");
}

test "a kind literal is a Kind" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectType(fix.lit(.{ .kind = .{ .name = "class_declaration", .id = 42 } }), "Kind");
}

test "a synthesized operator takes scalars, not filters" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `op[=] : Eq a => a -> a -> Bool`. Applying it to two ints is fine.
    const eq = try fix.synthesize("op[=]", .{ .operator = .eq });
    const applied = try fix.app(
        try fix.app(fix.sym(eq), fix.lit(.{ .number = 1 })),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectType(applied, "Bool");
}

test "an operator's constraint is refuted on a regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/015`: `r"a" = r"a"` fails `Eq regex`.
    const eq = try fix.synthesize("op[=]", .{ .operator = .eq });
    const applied = try fix.app(
        try fix.app(fix.sym(eq), fix.regexLit("a")),
        fix.regexLit("a"),
    );
    try fix.expectFails(applied, .unsatisfied_constraint);
}

test "ordering two nodes is refuted while comparing them is not" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/019`'s point: `node` has `Eq` but not `Ord`.
    const node_of = try fix.define("node_of", .{ .type = types.node_type });
    const lt = try fix.synthesize("op[<]", .{ .operator = .lt });
    const ordered = try fix.app(
        try fix.app(fix.sym(lt), fix.sym(node_of)),
        fix.sym(node_of),
    );
    try fix.expectFails(ordered, .unsatisfied_constraint);
}

test "a record applied to two field values yields a record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `{ k = kind n, n = 1 }` after desugaring.
    const record = try fix.synthesize(
        "record[k,n]",
        .{ .record = &.{ "k", "n" } },
    );
    const a_string = try fix.define("a_string", .{ .type = types.string_type });
    const an_int = try fix.define("an_int", .{ .type = types.int_type });

    const applied = try fix.app(
        try fix.app(fix.sym(record), fix.sym(a_string)),
        fix.sym(an_int),
    );
    try fix.expectType(applied, "{k: String, n: Int}");
}

test "record fields are independent" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Each field quantifies its own variable, so fields of unrelated types sit
    // beside each other. Under the filter-typed record they shared an input
    // and this was a mismatch.
    const record = try fix.synthesize(
        "record[a,b]",
        .{ .record = &.{ "a", "b" } },
    );
    const a_node = try fix.define("a_node", .{ .type = types.node_type });
    const a_regex = try fix.define("a_regex", .{ .type = types.regex_type });

    const applied = try fix.app(
        try fix.app(fix.sym(record), fix.sym(a_node)),
        fix.sym(a_regex),
    );
    try fix.expectType(applied, "{a: Node, b: Regex}");
}

test "a synthesized field access composes with a kind test" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `children | of_kind :class_declaration | .name`, the navigation chain
    // every fixture opens with, as Core composition.
    const compose = try fix.define("compose", .{
        .quantified = 3,
        .type = try types.func(
            fix.subst.arena,
            try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(1)),
            try types.func(
                fix.subst.arena,
                try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(1), types.variable_type(2)),
                try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(2)),
            ),
        ),
    });
    const children = try fix.define("children", .{
        .type = try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.node_type),
    });
    const of_kind = try fix.define("of_kind", .{
        .type = try types.func(
            fix.subst.arena,
            types.kind_type,
            try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.node_type),
        ),
    });
    const class_declaration = try fix.app(
        fix.sym(of_kind),
        fix.lit(.{ .kind = .{ .name = "class_declaration", .id = 1 } }),
    );
    const field = try fix.synthesize("field[name]", .{ .field = .{ .name = "name", .id = 2 } });

    const first = try fix.app(try fix.app(fix.sym(compose), fix.sym(children)), class_declaration);
    const chain = try fix.app(try fix.app(fix.sym(compose), first), fix.sym(field));
    try fix.expectType(chain, "Node -> [Node]");
}
