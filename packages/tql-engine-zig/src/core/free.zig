//! Which symbols a Core term mentions.
//!
//! Every binder is globally unique, interned once by resolution, so two
//! binders never share a SymbolId and a bound name cannot shadow another. No
//! walk here tracks scope.

const std = @import("std");
const core = @import("../core.zig");

const Allocator = std.mem.Allocator;

/// How a symbol appears in a term.
pub const Role = enum { use, binder };

fn VisitError(comptime visit: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(visit)).@"fn".return_type.?).error_union.error_set;
}

/// Visit every symbol in `term`, in source order, until `visit` returns true.
/// Returns whether it did.
pub fn anyMention(term: core.Term, context: anytype, comptime visit: anytype) VisitError(visit)!bool {
    switch (term.kind) {
        .literal => return false,
        .symbol => |symbol| return try visit(context, symbol, .use),
        .lambda => |lambda| {
            if (try visit(context, lambda.parameter, .binder)) return true;
            return try anyMention(lambda.body, context, visit);
        },
        .apply => |apply| {
            if (try anyMention(apply.function, context, visit)) return true;
            return try anyMention(apply.argument, context, visit);
        },
        .case => |case_term| {
            if (try anyMention(case_term.scrutinee, context, visit)) return true;
            for (case_term.alternatives) |alternative| {
                for (alternative.binders) |binder| {
                    if (try visit(context, binder, .binder)) return true;
                }
                if (try anyMention(alternative.body, context, visit)) return true;
            }
            if (case_term.default) |default| return try anyMention(default, context, visit);
            return false;
        },
        .let => |let| {
            if (try anyMention(let.value, context, visit)) return true;
            if (try visit(context, let.name, .binder)) return true;
            return try anyMention(let.body, context, visit);
        },
        .letrec => |letrec| {
            for (letrec.bindings) |binding| {
                if (try visit(context, binding.name, .binder)) return true;
            }
            for (letrec.bindings) |binding| {
                if (try anyMention(binding.value, context, visit)) return true;
            }
            return try anyMention(letrec.body, context, visit);
        },
    }
}

/// Whether `term` reads `symbol`.
pub fn occurs(term: core.Term, symbol: core.SymbolId) bool {
    return anyMention(term, symbol, isUseOf) catch |err| switch (err) {};
}

fn isUseOf(symbol: core.SymbolId, mention: core.SymbolId, role: Role) error{}!bool {
    return role == .use and mention == symbol;
}

/// Collect the free variables of `term` into `out`, in first-mention order.
///
/// Globals, constructors and primitives are symbols too, and only a symbol in
/// `locals` is collected.
///
/// Preconditions:
/// - No binder in a walked term is in `locals`.
pub const Collector = struct {
    gpa: Allocator,
    /// The symbols to collect.
    locals: Locals,

    out: std.ArrayList(core.SymbolId) = .empty,

    pub fn deinit(self: *Collector) void {
        self.out.deinit(self.gpa);
    }

    pub const Locals = union(enum) {
        list: []const core.SymbolId,
        keys: *const std.AutoHashMapUnmanaged(core.SymbolId, u32),

        fn contains(self: Locals, symbol: core.SymbolId) bool {
            return switch (self) {
                .list => |list| std.mem.indexOfScalar(core.SymbolId, list, symbol) != null,
                .keys => |keys| keys.contains(symbol),
            };
        }
    };

    pub fn walk(self: *Collector, term: core.Term) Allocator.Error!void {
        _ = try anyMention(term, self, visit);
    }

    fn visit(self: *Collector, symbol: core.SymbolId, role: Role) Allocator.Error!bool {
        const local = self.locals.contains(symbol);
        switch (role) {
            .binder => std.debug.assert(!local),
            .use => if (local and std.mem.indexOfScalar(core.SymbolId, self.out.items, symbol) == null) {
                try self.out.append(self.gpa, symbol);
            },
        }
        return false;
    }
};

const testing = std.testing;

const span = @import("../diagnostic.zig").Span.unknown;

fn sym(id: u32) core.Term {
    return .{ .kind = .{ .symbol = @enumFromInt(id) }, .span = span };
}

test "a bare local is free" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{@enumFromInt(7)} } };
    defer collector.deinit();

    try collector.walk(sym(7));
    try testing.expectEqualSlices(core.SymbolId, &.{@enumFromInt(7)}, collector.out.items);
}

test "a global is not free" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{} } };
    defer collector.deinit();

    try collector.walk(sym(3));
    try testing.expectEqual(0, collector.out.items.len);
}

test "a lambda's parameter is not free in its body" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{@enumFromInt(2)} } };
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `\x -> x y`: `y` is free, `x` is not.
    const body = try builder.apply(sym(1), sym(2), span);
    const lambda = try builder.lambda(@enumFromInt(1), body, span);

    try collector.walk(lambda);
    try testing.expectEqualSlices(core.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a variable mentioned twice is captured once" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{@enumFromInt(5)} } };
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    const term = try builder.apply(sym(5), sym(5), span);
    try collector.walk(term);
    try testing.expectEqualSlices(core.SymbolId, &.{@enumFromInt(5)}, collector.out.items);
}

test "a letrec binding is not free in its own right-hand side" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{@enumFromInt(2)} } };
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `letrec { a = a b } in a`: only `b` is free.
    const rhs = try builder.apply(sym(1), sym(2), span);
    const bindings = try arena.allocator().alloc(core.Letrec.Binding, 1);
    bindings[0] = .{ .name = @enumFromInt(1), .value = rhs };
    const term = try builder.letrec(bindings, sym(1), span);

    try collector.walk(term);
    try testing.expectEqualSlices(core.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a let binding's value is walked and its binder is not collected" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `let a = b in a`: only `b` is free.
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{@enumFromInt(2)} } };
    defer collector.deinit();
    try collector.walk(try builder.let(@enumFromInt(1), sym(2), sym(1), span));
    try testing.expectEqualSlices(core.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a case alternative's binders are not free in its body" {
    const gpa = testing.allocator;
    var collector: Collector = .{ .gpa = gpa, .locals = .{ .list = &.{ @enumFromInt(1), @enumFromInt(4) } } };
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `case s of { C h t -> h t g }`: only `s` and `g` are free.
    const body = try builder.apply(try builder.apply(sym(2), sym(3), span), sym(4), span);
    const alternatives = try arena.allocator().alloc(core.Case.Alternative, 1);
    const binders = try arena.allocator().alloc(core.SymbolId, 2);
    binders[0] = @enumFromInt(2);
    binders[1] = @enumFromInt(3);
    alternatives[0] = .{ .constructor = @enumFromInt(9), .binders = binders, .body = body };
    const term = try builder.case(sym(1), alternatives, span);

    try collector.walk(term);
    try testing.expectEqualSlices(
        core.SymbolId,
        &.{ @enumFromInt(1), @enumFromInt(4) },
        collector.out.items,
    );
}

test "occurs sees a use under a binder" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `\x -> y`
    const lambda = try builder.lambda(@enumFromInt(1), sym(2), span);
    try testing.expect(occurs(lambda, @enumFromInt(2)));
    try testing.expect(!occurs(lambda, @enumFromInt(1)));
}
