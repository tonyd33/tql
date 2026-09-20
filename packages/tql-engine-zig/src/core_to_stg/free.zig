//! Free variables of a Core term.
//!
//! A closure captures exactly the locals its body mentions but does not bind.
//!
//! Every binder is globally unique, interned once by resolution, so two
//! binders never share a SymbolId and a bound name cannot shadow another. The
//! walk carries a flat bound set, not a scope chain.

const std = @import("std");
const core = @import("../lang/core.zig");
const symbols = @import("../lang/symbols.zig");

const Allocator = std.mem.Allocator;

/// Collect the free variables of `term` into `out`, in first-mention order.
///
/// `bound` holds the binders already in scope. Globals, constructors and
/// primitives are symbols too, so `is_local` filters them out.
pub const Collector = struct {
    gpa: Allocator,
    /// Whether a symbol is a local at all. A global is never captured.
    is_local: *const fn (context: *const anyopaque, symbol: symbols.SymbolId) bool,
    context: *const anyopaque,

    bound: std.ArrayList(symbols.SymbolId) = .empty,
    out: std.ArrayList(symbols.SymbolId) = .empty,

    pub fn deinit(self: *Collector) void {
        self.bound.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    fn isBound(self: *const Collector, symbol: symbols.SymbolId) bool {
        return std.mem.indexOfScalar(symbols.SymbolId, self.bound.items, symbol) != null;
    }

    fn collected(self: *const Collector, symbol: symbols.SymbolId) bool {
        return std.mem.indexOfScalar(symbols.SymbolId, self.out.items, symbol) != null;
    }

    pub fn walk(self: *Collector, term: core.Term) Allocator.Error!void {
        switch (term.kind) {
            .literal => {},
            .symbol => |symbol| {
                if (self.isBound(symbol)) return;
                if (self.collected(symbol)) return;
                if (!self.is_local(self.context, symbol)) return;
                try self.out.append(self.gpa, symbol);
            },
            .lambda => |lambda| {
                const mark = self.bound.items.len;
                try self.bound.append(self.gpa, lambda.parameter);
                try self.walk(lambda.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .apply => |apply| {
                try self.walk(apply.function);
                try self.walk(apply.argument);
            },
            .case => |case_term| {
                try self.walk(case_term.scrutinee);
                for (case_term.alternatives) |alternative| {
                    const mark = self.bound.items.len;
                    for (alternative.binders) |binder| try self.bound.append(self.gpa, binder);
                    try self.walk(alternative.body);
                    self.bound.shrinkRetainingCapacity(mark);
                }
            },
            .letrec => |letrec| {
                // Recursive: every binding is in scope in every right-hand
                // side as well as in the body, so nothing here is free.
                const mark = self.bound.items.len;
                for (letrec.bindings) |binding| try self.bound.append(self.gpa, binding.name);
                for (letrec.bindings) |binding| try self.walk(binding.value);
                try self.walk(letrec.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
            .bind => |bind_term| {
                // `bind x <- v in body` binds `x` in the body only; `v` is
                // evaluated in the enclosing scope.
                try self.walk(bind_term.value);
                const mark = self.bound.items.len;
                try self.bound.append(self.gpa, bind_term.name);
                try self.walk(bind_term.body);
                self.bound.shrinkRetainingCapacity(mark);
            },
        }
    }
};

const testing = std.testing;

/// Treats every symbol below `threshold` as a global, so a test can build
/// terms without a program.
const Threshold = struct {
    value: u32,

    fn isLocal(context: *const anyopaque, symbol: symbols.SymbolId) bool {
        const self: *const Threshold = @ptrCast(@alignCast(context));
        return @intFromEnum(symbol) >= self.value;
    }
};

fn collectorFor(gpa: Allocator, threshold: *const Threshold) Collector {
    return .{ .gpa = gpa, .is_local = Threshold.isLocal, .context = threshold };
}

const span = @import("../lang/diagnostic.zig").Span.unknown;

fn sym(id: u32) core.Term {
    return .{ .kind = .{ .symbol = @enumFromInt(id) }, .span = span };
}

test "a bare local is free" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    try collector.walk(sym(7));
    try testing.expectEqualSlices(symbols.SymbolId, &.{@enumFromInt(7)}, collector.out.items);
}

test "a global is not free" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 10 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    try collector.walk(sym(3));
    try testing.expectEqual(0, collector.out.items.len);
}

test "a lambda's parameter is not free in its body" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `\x -> x y`: `y` is free, `x` is not.
    const body = try builder.apply(sym(1), sym(2), span);
    const lambda = try builder.lambda(@enumFromInt(1), body, span);

    try collector.walk(lambda);
    try testing.expectEqualSlices(symbols.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a variable mentioned twice is captured once" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    const term = try builder.apply(sym(5), sym(5), span);
    try collector.walk(term);
    try testing.expectEqualSlices(symbols.SymbolId, &.{@enumFromInt(5)}, collector.out.items);
}

test "a letrec binding is not free in its own right-hand side" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
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
    try testing.expectEqualSlices(symbols.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a bind's value sees the enclosing scope, its body sees the binder" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `bind x <- x in x`: the outer `x` in the value position is a different
    // symbol from the binder.
    const term = try builder.bind(@enumFromInt(1), sym(2), sym(1), span);

    try collector.walk(term);
    try testing.expectEqualSlices(symbols.SymbolId, &.{@enumFromInt(2)}, collector.out.items);
}

test "a case alternative's binders are not free in its body" {
    const gpa = testing.allocator;
    const threshold: Threshold = .{ .value = 0 };
    var collector = collectorFor(gpa, &threshold);
    defer collector.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const builder: core.Builder = .{ .allocator = arena.allocator() };

    // `case s of { C h t -> h t g }`: only `s` and `g` are free.
    const body = try builder.apply(try builder.apply(sym(2), sym(3), span), sym(4), span);
    const alternatives = try arena.allocator().alloc(core.Case.Alternative, 1);
    const binders = try arena.allocator().alloc(symbols.SymbolId, 2);
    binders[0] = @enumFromInt(2);
    binders[1] = @enumFromInt(3);
    alternatives[0] = .{ .constructor = @enumFromInt(9), .binders = binders, .body = body };
    const term = try builder.case(sym(1), alternatives, span);

    try collector.walk(term);
    try testing.expectEqualSlices(
        symbols.SymbolId,
        &.{ @enumFromInt(1), @enumFromInt(4) },
        collector.out.items,
    );
}
