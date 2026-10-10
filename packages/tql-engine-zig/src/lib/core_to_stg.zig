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
                if (c.default) |default| try self.expr(default, scope);
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
            .let_no_escape => |let| {
                const depth = scope.items.len;
                for (let.joins) |join| {
                    try std.testing.expectEqual(depth, join.depth);
                    try scope.appendSlice(self.gpa, join.parameters);
                    try self.expr(join.body, scope);
                    scope.shrinkRetainingCapacity(depth);
                }
                try self.expr(let.body, scope);
            },
            .jump => |jump| {
                try std.testing.expectEqual(jump.target.parameters.len, jump.arguments.len);
                try std.testing.expect(jump.target.depth <= scope.items.len);
                for (jump.arguments) |argument| try self.atom(argument, scope.items);
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

test "a recursive join point loops in its enclosing frame" {
    const gpa = std.testing.allocator;
    var pb = try core.test_support.ProgramBuilder.init(gpa);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const main = try pb.global("main");
    const go = try pb.join("go", 2);
    const xs = try pb.local("xs");
    const acc = try pb.local("acc");
    const h = try pb.local("h");
    const t = try pb.local("t");

    // `joinrec go xs acc = case xs of { Nil -> acc; Cons h t -> jump go t (Cons h acc) }
    // in jump go [1, 2] []`
    const reversed = try pb.case(pb.symbol(xs), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(acc) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = try pb.apply(pb.symbol(go), &.{
            pb.symbol(t),
            try pb.apply(pb.symbol(cons), &.{ pb.symbol(h), pb.symbol(acc) }),
        }) },
    });
    const list = try pb.apply(pb.symbol(cons), &.{ pb.number(1), try pb.apply(pb.symbol(cons), &.{ pb.number(2), pb.symbol(nil) }) });
    try pb.define(main, try pb.letrec(
        &.{.{ .name = go, .value = try pb.lambda(&.{ xs, acc }, reversed) }},
        try pb.apply(pb.symbol(go), &.{ list, pb.symbol(nil) }),
    ));
    var program = try pb.program(main);
    try std.testing.expectEqual(null, try core.lint.program(gpa, &program));

    var translated = try translate(gpa, &program);
    defer translated.deinit();
    try expectPlaced(gpa, &translated);

    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const printer: stg.Printer = .{ .interner = &program.env.interner };
    try printer.definitions(translated.definitions, &w.writer);
    try std.testing.expectEqualStrings(
        \\main = {} \u {} ->
        \\  letrec-no-escape
        \\    go {xs,acc} -> case xs@0 of
        \\      Nil -> acc@1
        \\      Cons h t ->
        \\        let t0 = {h@2,acc@1} \u {} -> Cons h@0 acc@1 in
        \\        jump go t@3 t0@4
        \\  in
        \\  let
        \\    t3 = {} \u {} ->
        \\      let
        \\        t2 = {} \u {} ->
        \\          let c1 = Nil in
        \\          Cons 2 c1@0
        \\      in
        \\      Cons 1 t2@0
        \\    c4 = Nil
        \\  in
        \\  jump go t3@0 c4@1
    , w.written());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var machine = try stg.Machine.init(arena.allocator(), gpa, &translated);
    defer machine.deinit();
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    var jws: std.json.Stringify = .{ .writer = &json.writer };
    _ = try machine.serializeList(try machine.force(machine.global(main).?), &jws);
    try std.testing.expectEqualStrings("[2,1]", json.written());
}
