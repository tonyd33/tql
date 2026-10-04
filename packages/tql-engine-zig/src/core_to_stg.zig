//! Lowering: checked Core to STG terms.

const translate_mod = @import("core_to_stg/translate.zig");

/// Translates a checked program into the term language.
pub const translate = translate_mod.translate;

/// One program's translation state.
pub const Translator = translate_mod.Translator;

pub const Error = translate_mod.Error;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(translate_mod);
}

const std = @import("std");
const core = @import("core.zig");
const stg = @import("stg.zig");
const test_support = core.test_support;

const types = core.types;
const Allocator = std.mem.Allocator;

/// Walks translated terms, building each environment the way the evaluator
/// does, and fails on a local whose offset reads a slot bound to another name
/// or a global whose index names another definition.
const Placement = struct {
    gpa: Allocator,
    program: *const stg.Program,

    /// Spelled out because `closure` and `expr` are mutually recursive.
    const Failure = Allocator.Error || error{ TestUnexpectedResult, TestExpectedEqual };

    fn closure(self: Placement, c: *const stg.Closure, enclosing: []const core.SymbolId) Failure!void {
        var scope: std.ArrayList(core.SymbolId) = .empty;
        defer scope.deinit(self.gpa);
        for (c.free) |capture| {
            try expectLocal(capture, enclosing);
            try scope.append(self.gpa, capture.name);
        }
        try scope.appendSlice(self.gpa, c.parameters);
        try self.expr(c.body, &scope);
    }

    fn expr(self: Placement, e: stg.Expr, scope: *std.ArrayList(core.SymbolId)) Failure!void {
        switch (e) {
            .atom => |a| try self.atom(a, scope.items),
            .apply => |a| {
                try self.atom(a.callee, scope.items);
                for (a.arguments) |argument| try self.atom(argument, scope.items);
            },
            .constructed => |c| for (c.fields) |field| try self.atom(field, scope.items),
            .primitive => |p| for (p.arguments) |argument| try self.atom(argument, scope.items),
            .case => |c| {
                const mark = scope.items.len;
                try self.expr(c.scrutinee, scope);
                scope.shrinkRetainingCapacity(mark);
                for (c.alternatives) |alternative| {
                    try scope.appendSlice(self.gpa, alternative.binders);
                    try self.expr(alternative.body, scope);
                    scope.shrinkRetainingCapacity(mark);
                }
            },
            .let => |let| {
                const base = scope.items.len;
                for (let.bindings) |binding| try scope.append(self.gpa, binding.binder);
                const inner = if (let.recursive) scope.items else scope.items[0..base];
                for (let.bindings) |binding| switch (binding.value) {
                    .closure => |c| try self.closure(c, inner),
                    .constructed => |c| for (c.fields) |field| try self.atom(field, inner),
                };
                try self.expr(let.body, scope);
            },
        }
    }

    fn atom(self: Placement, a: stg.Atom, scope: []const core.SymbolId) !void {
        switch (a) {
            .local => |local| try expectLocal(local, scope),
            .global => |g| {
                try std.testing.expect(g.index < self.program.definitions.len);
                try std.testing.expectEqual(g.symbol, self.program.definitions[g.index].symbol);
            },
            .literal => {},
        }
    }

    fn expectLocal(local: stg.Local, scope: []const core.SymbolId) !void {
        try std.testing.expect(local.offset < scope.len);
        try std.testing.expectEqual(local.name, scope[local.offset]);
    }
};

/// Checks the placement of every local and global in every definition of
/// `program`.
pub fn expectPlaced(gpa: Allocator, program: *const stg.Program) !void {
    const placement: Placement = .{ .gpa = gpa, .program = program };
    for (program.definitions) |definition| try placement.closure(definition.value, &.{});
}

fn expectTranslationPlaced(program: *core.Program) !void {
    var translated = try translate(std.testing.allocator, program);
    defer translated.deinit();
    try expectPlaced(std.testing.allocator, &translated);
}

/// Translates `program` and asserts how the closure defining `name` prints.
fn expectDefinition(program: *core.Program, name: core.SymbolId, expected: []const u8) !void {
    var translated = try translate(std.testing.allocator, program);
    defer translated.deinit();

    const definition = for (translated.definitions) |definition| {
        if (definition.symbol == name) break definition;
    } else return error.TestUnexpectedResult;

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    const printer: stg.Printer = .{ .interner = &program.env.interner };
    try printer.closure(definition.value, &w.writer);
    try std.testing.expectEqualStrings(expected, w.written());
}

/// Defines `append xs ys = case xs of { Nil -> ys; Cons h t -> Cons h (append t ys) }`
/// and returns its `xs`.
fn defineAppend(pb: *test_support.ProgramBuilder) !core.SymbolId {
    const append = try pb.global("append");
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const xs = try pb.local("xs");
    const ys = try pb.local("ys");
    const h = try pb.local("h");
    const t = try pb.local("t");
    try pb.define(append, try pb.lambda(&.{ xs, ys }, try pb.case(pb.symbol(xs), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(ys) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = try pb.apply(pb.symbol(cons), &.{
            pb.symbol(h),
            try pb.apply(pb.symbol(append), &.{ pb.symbol(t), pb.symbol(ys) }),
        }) },
    })));
    return xs;
}

test "binders under a scrutinee's case and let do not shift an alternative's" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();

    try pb.datatype("P", &.{.{ "Mk", &.{ types.int_type, types.int_type } }});
    const mk = try pb.global("Mk");
    const plus = try pb.operator(.add);

    // fst p = case p of { Mk a b -> a }
    const fst = try pb.global("fst");
    {
        const p = try pb.local("p");
        const a = try pb.local("a");
        const b = try pb.local("b");
        try pb.define(fst, try pb.lambda(&.{p}, try pb.case(pb.symbol(p), &.{
            .{ .constructor = mk, .binders = &.{ a, b }, .body = pb.symbol(a) },
        })));
    }

    // pick p q = case (case p of { Mk a b -> Mk b a }) of { Mk x y -> x + y + fst q }
    const pick = try pb.global("pick");
    {
        const p = try pb.local("p");
        const q = try pb.local("q");
        const a = try pb.local("a");
        const b = try pb.local("b");
        const x = try pb.local("x");
        const y = try pb.local("y");
        const inner = try pb.case(pb.symbol(p), &.{
            .{ .constructor = mk, .binders = &.{ a, b }, .body = try pb.apply(pb.symbol(mk), &.{ pb.symbol(b), pb.symbol(a) }) },
        });
        const sum = try pb.apply(pb.symbol(plus), &.{
            try pb.apply(pb.symbol(plus), &.{ pb.symbol(x), pb.symbol(y) }),
            try pb.apply(pb.symbol(fst), &.{pb.symbol(q)}),
        });
        try pb.define(pick, try pb.lambda(&.{ p, q }, try pb.case(inner, &.{
            .{ .constructor = mk, .binders = &.{ x, y }, .body = sum },
        })));
    }

    // pack q = case (let { s = 5 } in Mk s 6) of { Mk x y -> x + y + fst q }
    {
        const q = try pb.local("q");
        const s = try pb.local("s");
        const x = try pb.local("x");
        const y = try pb.local("y");
        const scrutinee = try pb.letrec(
            &.{.{ .name = s, .value = pb.number(5) }},
            try pb.apply(pb.symbol(mk), &.{ pb.symbol(s), pb.number(6) }),
        );
        const sum = try pb.apply(pb.symbol(plus), &.{
            try pb.apply(pb.symbol(plus), &.{ pb.symbol(x), pb.symbol(y) }),
            try pb.apply(pb.symbol(fst), &.{pb.symbol(q)}),
        });
        try pb.define(try pb.global("pack"), try pb.lambda(&.{q}, try pb.case(scrutinee, &.{
            .{ .constructor = mk, .binders = &.{ x, y }, .body = sum },
        })));
    }

    var program = try pb.program(pick);
    try expectTranslationPlaced(&program);
}

test "captures resolve against the environment that allocates the closure" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();

    const false_ = try pb.global("False");
    const true_ = try pb.global("True");
    const eq = try pb.operator(.eq);
    const plus = try pb.operator(.add);
    const minus = try pb.operator(.subtract);
    const times = try pb.operator(.multiply);

    // count_to limit = let { go n = if n = limit then n else go (n + 1) } in go 0
    const count_to = try pb.global("count_to");
    {
        const limit = try pb.local("limit");
        const go = try pb.local("go");
        const n = try pb.local("n");
        const step = try pb.case(try pb.apply(pb.symbol(eq), &.{ pb.symbol(n), pb.symbol(limit) }), &.{
            .{ .constructor = false_, .binders = &.{}, .body = try pb.apply(pb.symbol(go), &.{
                try pb.apply(pb.symbol(plus), &.{ pb.symbol(n), pb.number(1) }),
            }) },
            .{ .constructor = true_, .binders = &.{}, .body = pb.symbol(n) },
        });
        try pb.define(count_to, try pb.lambda(&.{limit}, try pb.letrec(
            &.{.{ .name = go, .value = try pb.lambda(&.{n}, step) }},
            try pb.apply(pb.symbol(go), &.{pb.number(0)}),
        )));
    }

    // spread a b c = \x -> c - a * x - b
    {
        const a = try pb.local("a");
        const b = try pb.local("b");
        const c = try pb.local("c");
        const x = try pb.local("x");
        const body = try pb.apply(pb.symbol(minus), &.{
            try pb.apply(pb.symbol(minus), &.{
                pb.symbol(c),
                try pb.apply(pb.symbol(times), &.{ pb.symbol(a), pb.symbol(x) }),
            }),
            pb.symbol(b),
        });
        try pb.define(try pb.global("spread"), try pb.lambda(&.{ a, b, c }, try pb.lambda(&.{x}, body)));
    }

    var program = try pb.program(count_to);
    try expectTranslationPlaced(&program);
}

test "a closure prints its captures, its update flag and its parameters" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();

    // spread a b = let { k = b - a } in k
    const spread = try pb.global("spread");
    const a = try pb.local("a");
    const b = try pb.local("b");
    const k = try pb.local("k");
    try pb.define(spread, try pb.lambda(&.{ a, b }, try pb.letrec(
        &.{.{ .name = k, .value = try pb.apply(pb.symbol(try pb.operator(.subtract)), &.{ pb.symbol(b), pb.symbol(a) }) }},
        pb.symbol(k),
    )));

    var program = try pb.program(spread);
    try expectDefinition(
        &program,
        spread,
        \\{} \u {} ->
        \\  let
        \\    t0 = {} \n {a,b} ->
        \\      letrec k = {b@1,a@0} \u {} -> op[-]# b@0 a@1 in
        \\      k@2
        \\  in
        \\  t0@0
        ,
    );
}

test "a let becomes a non-recursive let of one binding" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();

    // spread a b = let k = b - a in k
    const spread = try pb.global("spread");
    const a = try pb.local("a");
    const b = try pb.local("b");
    const k = try pb.local("k");
    try pb.define(spread, try pb.lambda(&.{ a, b }, try pb.let(
        k,
        try pb.apply(pb.symbol(try pb.operator(.subtract)), &.{ pb.symbol(b), pb.symbol(a) }),
        pb.symbol(k),
    )));

    var program = try pb.program(spread);
    try expectTranslationPlaced(&program);
    try expectDefinition(
        &program,
        spread,
        \\{} \u {} ->
        \\  let
        \\    t0 = {} \n {a,b} ->
        \\      let k = {b@1,a@0} \u {} -> op[-]# b@0 a@1 in
        \\      k@2
        \\  in
        \\  t0@0
        ,
    );
}

test "a constructor field that is not an atom becomes a thunk" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();

    _ = try defineAppend(&pb);
    const append = try pb.global("append");

    // The recursive call is let-bound to a thunk and the `Cons` takes that
    // binder as an atom, so an evaluator cannot force the field early.
    var program = try pb.program(append);
    try expectDefinition(
        &program,
        append,
        \\{} \u {} ->
        \\  let
        \\    t1 = {} \n {xs,ys} -> case xs@0 of
        \\      Nil -> ys@1
        \\      Cons h t ->
        \\        let t0 = {t@3,ys@1} \u {} -> append t@0 ys@1 in
        \\        Cons h@2 t0@4
        \\  in
        \\  t1@0
        ,
    );
}
