//! Renders STG-shaped terms, for tests and for reading what translation
//! produced.

const std = @import("std");
const stg = @import("terms.zig");
const core = @import("../core.zig");
const string_literal = @import("../lang/string_literal.zig");

pub const Printer = struct {
    interner: *const core.Interner,

    /// Spelled out because `expr`, `closure` and `allocation` are mutually
    /// recursive, and an inferred set cannot close over that cycle.
    pub const Error = std.Io.Writer.Error;

    pub fn closure(self: Printer, c: *const stg.Closure, w: *std.Io.Writer) Error!void {
        try self.writeClosure(c, w, 0, null);
    }

    pub fn expr(self: Printer, e: stg.Expr, w: *std.Io.Writer) Error!void {
        try self.writeExpr(e, w, 0, null);
    }

    /// Write `name = closure` for each definition in `list`.
    pub fn definitions(self: Printer, list: []const stg.Definition, w: *std.Io.Writer) Error!void {
        for (list, 0..) |d, i| {
            if (i > 0) try w.writeByte('\n');
            try w.print("{s} = ", .{self.interner.spelling(d.symbol)});
            try self.closure(d.value, w);
        }
    }

    const Scope = struct {
        symbol: core.SymbolId,
        primes: u32,
        parent: ?*Scope,
    };

    /// Binders that enter scope together.
    const Group = union(enum) {
        closure: *const stg.Closure,
        alternative: *const stg.Alternative,
        let: *const stg.Expr.Let,

        fn len(g: Group) usize {
            return switch (g) {
                .closure => |c| c.parameters.len,
                .alternative => |a| a.binders.len,
                .let => |l| l.bindings.len,
            };
        }

        fn binder(g: Group, i: usize) core.SymbolId {
            return switch (g) {
                .closure => |c| c.parameters[i],
                .alternative => |a| a.binders[i],
                .let => |l| l.bindings[i].binder,
            };
        }
    };

    fn writeExpr(self: Printer, e: stg.Expr, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (e) {
            .atom => |a| try self.writeAtom(a, w, .top, scope),
            .apply => |apply| {
                try self.writeAtom(apply.callee, w, .top, scope);
                try self.writeArguments(apply.arguments, w, scope);
            },
            .constructed => |c| {
                try w.writeAll(self.interner.spelling(c.constructor));
                try self.writeArguments(c.fields, w, scope);
            },
            .primitive => |p| {
                try w.print("{s}#", .{self.interner.spelling(p.symbol)});
                try self.writeArguments(p.arguments, w, scope);
            },
            .case => |c| {
                try w.writeAll("case ");
                if (isFlat(c.scrutinee)) {
                    try self.writeExpr(c.scrutinee, w, indent, scope);
                } else {
                    try w.writeByte('(');
                    try newline(w, indent + 2);
                    try self.writeExpr(c.scrutinee, w, indent + 2, scope);
                    try newline(w, indent);
                    try w.writeByte(')');
                }
                try w.writeAll(" of");
                for (c.alternatives) |*alternative| {
                    try newline(w, indent + 2);
                    try w.writeAll(self.interner.spelling(alternative.constructor));
                    try self.enter(.{ .alternative = alternative }, 0, w, indent + 2, scope);
                }
            },
            .let => |let| try self.enter(.{ .let = let }, 0, w, indent, scope),
        }
    }

    /// Write ` e`, or `e` on its own line at `indent + 2` when it is a `let`.
    fn writeAfterArrow(self: Printer, e: stg.Expr, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (e) {
            .let => {
                try newline(w, indent + 2);
                try self.writeExpr(e, w, indent + 2, scope);
            },
            else => {
                try w.writeByte(' ');
                try self.writeExpr(e, w, indent, scope);
            },
        }
    }

    fn writeClosure(self: Printer, c: *const stg.Closure, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        try self.enter(.{ .closure = c }, 0, w, indent, scope);
    }

    fn writeAllocation(self: Printer, a: stg.Allocation, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (a) {
            .closure => |c| try self.writeClosure(c, w, indent, scope),
            .constructed => |c| {
                try w.writeAll(self.interner.spelling(c.constructor));
                try self.writeArguments(c.fields, w, scope);
            },
        }
    }

    /// Bring binders `i..` of `g` into scope, then write what they scope.
    fn enter(self: Printer, g: Group, i: usize, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        if (i < g.len()) {
            var node: Scope = .{ .symbol = g.binder(i), .primes = 0, .parent = scope };
            return self.enter(g, i + 1, w, indent, &node);
        }
        // The group is the innermost `g.len()` nodes, newest first.
        for (0..g.len()) |k| {
            var node = scope.?;
            for (0..g.len() - 1 - k) |_| node = node.parent.?;
            node.primes = self.primesFor(g, node.symbol, scope);
        }
        try self.writeScoped(g, w, indent, scope);
    }

    fn writeScoped(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (g) {
            .closure => |c| {
                const enclosing = outside(scope, c.parameters.len);
                try w.writeByte('{');
                for (c.free, 0..) |capture, i| {
                    if (i > 0) try w.writeByte(',');
                    try self.writeLocal(capture, w, enclosing);
                }
                try w.writeAll("} ");
                try w.writeAll(if (c.parameters.len == 0) "\\u" else "\\n");
                try w.writeAll(" {");
                for (c.parameters, 0..) |p, i| {
                    if (i > 0) try w.writeByte(',');
                    try self.writeName(p, w, scope);
                }
                try w.writeAll("} ->");
                try self.writeAfterArrow(c.body, w, indent, scope);
            },
            .alternative => |a| {
                for (a.binders) |binder| {
                    try w.writeByte(' ');
                    try self.writeName(binder, w, scope);
                }
                try w.writeAll(" ->");
                try self.writeAfterArrow(a.body, w, indent, scope);
            },
            .let => |let| {
                const keyword = if (let.recursive) "letrec" else "let";
                if (let.bindings.len == 1 and isAllocationFlat(let.bindings[0].value)) {
                    try w.print("{s} ", .{keyword});
                    try self.writeName(let.bindings[0].binder, w, scope);
                    try w.writeAll(" = ");
                    try self.writeAllocation(let.bindings[0].value, w, indent, scope);
                    try w.writeAll(" in");
                } else {
                    try w.writeAll(keyword);
                    for (let.bindings) |binding| {
                        try newline(w, indent + 2);
                        try self.writeName(binding.binder, w, scope);
                        try w.writeAll(" = ");
                        try self.writeAllocation(binding.value, w, indent + 2, scope);
                    }
                    try newline(w, indent);
                    try w.writeAll("in");
                }
                try newline(w, indent);
                try self.writeExpr(let.body, w, indent, scope);
            },
        }
    }

    /// The scope outside the innermost `n` nodes.
    fn outside(scope: ?*Scope, n: usize) ?*Scope {
        var node = scope;
        for (0..n) |_| node = node.?.parent;
        return node;
    }

    fn primesFor(self: Printer, g: Group, binder: core.SymbolId, scope: ?*Scope) u32 {
        const spelling = self.interner.spelling(binder);
        if (std.mem.eql(u8, spelling, "_")) return 0;
        var primes: u32 = 0;
        while (self.groupCaptures(g, binder, spelling, primes, scope)) primes += 1;
        return primes;
    }

    fn groupCaptures(self: Printer, g: Group, binder: core.SymbolId, spelling: []const u8, primes: u32, scope: ?*Scope) bool {
        const target: Target = .{ .binder = binder, .spelling = spelling, .primes = primes, .scope = scope };
        return switch (g) {
            .closure => |c| self.captures(c.body, target),
            .alternative => |a| self.captures(a.body, target),
            .let => |let| {
                for (let.bindings) |binding| {
                    if (self.allocationCaptures(binding.value, target)) return true;
                }
                return self.captures(let.body, target);
            },
        };
    }

    /// A printed name a reference must not resolve to: `spelling` with
    /// `primes` primes, belonging to any symbol other than `binder`.
    const Target = struct {
        binder: core.SymbolId,
        spelling: []const u8,
        primes: u32,
        scope: ?*Scope,
    };

    fn captures(self: Printer, e: stg.Expr, target: Target) bool {
        return switch (e) {
            .atom => |a| self.atomCaptures(a, target),
            .apply => |apply| self.atomCaptures(apply.callee, target) or
                self.atomsCapture(apply.arguments, target),
            .constructed => |c| self.atomsCapture(c.fields, target),
            .primitive => |p| self.atomsCapture(p.arguments, target),
            .case => |c| {
                if (self.captures(c.scrutinee, target)) return true;
                for (c.alternatives) |alternative| {
                    if (self.captures(alternative.body, target)) return true;
                }
                return false;
            },
            .let => |let| {
                for (let.bindings) |binding| {
                    if (self.allocationCaptures(binding.value, target)) return true;
                }
                return self.captures(let.body, target);
            },
        };
    }

    fn allocationCaptures(self: Printer, a: stg.Allocation, target: Target) bool {
        return switch (a) {
            .closure => |c| {
                for (c.free) |capture| {
                    if (self.symbolCaptures(capture.name, target)) return true;
                }
                return self.captures(c.body, target);
            },
            .constructed => |c| self.atomsCapture(c.fields, target),
        };
    }

    fn atomsCapture(self: Printer, list: []const stg.Atom, target: Target) bool {
        for (list) |a| {
            if (self.atomCaptures(a, target)) return true;
        }
        return false;
    }

    fn atomCaptures(self: Printer, a: stg.Atom, target: Target) bool {
        return switch (a) {
            .local => |local| self.symbolCaptures(local.name, target),
            .global => |g| self.symbolCaptures(g.symbol, target),
            .literal => false,
        };
    }

    fn symbolCaptures(self: Printer, id: core.SymbolId, target: Target) bool {
        return id != target.binder and
            std.mem.eql(u8, self.interner.spelling(id), target.spelling) and
            self.outerPrimes(id, target.scope) == target.primes;
    }

    /// The primes `id` prints with if it is in scope or a global, else null.
    fn outerPrimes(self: Printer, id: core.SymbolId, scope: ?*Scope) ?u32 {
        var node = scope;
        while (node) |n| : (node = n.parent) {
            if (n.symbol == id) return n.primes;
        }
        const global = self.interner.by_spelling.get(self.interner.spelling(id)) orelse return null;
        return if (global == id) 0 else null;
    }

    fn writeName(self: Printer, id: core.SymbolId, w: *std.Io.Writer, scope: ?*Scope) Error!void {
        try w.writeAll(self.interner.spelling(id));
        try w.splatByteAll('\'', self.outerPrimes(id, scope) orelse 0);
    }

    fn writeLocal(self: Printer, local: stg.Local, w: *std.Io.Writer, scope: ?*Scope) Error!void {
        try self.writeName(local.name, w, scope);
        try w.print("@{d}", .{local.offset});
    }

    const Position = enum { top, argument };

    fn writeAtom(self: Printer, a: stg.Atom, w: *std.Io.Writer, position: Position, scope: ?*Scope) Error!void {
        switch (a) {
            .local => |local| try self.writeLocal(local, w, scope),
            .global => |g| try w.writeAll(self.interner.spelling(g.symbol)),
            .literal => |thunk| switch (thunk.state.evaluated) {
                .number => |n| if (position == .argument and n < 0)
                    try w.print("({d})", .{n})
                else
                    try w.print("{d}", .{n}),
                .string => |s| try w.print("\"{f}\"", .{string_literal.fmt(s)}),
                .regex => |r| try w.print("r\"{s}\"", .{r.pattern}),
                .kind => |k| try w.print(":{s}", .{k.name}),
                else => unreachable,
            },
        }
    }

    fn writeArguments(self: Printer, list: []const stg.Atom, w: *std.Io.Writer, scope: ?*Scope) Error!void {
        for (list) |a| {
            try w.writeByte(' ');
            try self.writeAtom(a, w, .argument, scope);
        }
    }

    fn newline(w: *std.Io.Writer, indent: usize) Error!void {
        try w.writeByte('\n');
        try w.splatByteAll(' ', indent);
    }

    fn isFlat(e: stg.Expr) bool {
        return switch (e) {
            .atom, .apply, .constructed, .primitive => true,
            .case, .let => false,
        };
    }

    fn isAllocationFlat(a: stg.Allocation) bool {
        return switch (a) {
            .closure => |c| isFlat(c.body),
            .constructed => true,
        };
    }
};

const value = @import("value.zig");

const TestTerms = struct {
    arena: std.heap.ArenaAllocator,
    interner: core.Interner,

    fn init(self: *TestTerms) void {
        self.arena = .init(std.testing.allocator);
        self.interner = .init(self.arena.allocator());
    }

    fn deinit(self: *TestTerms) void {
        self.arena.deinit();
    }

    fn allocator(self: *TestTerms) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn global(self: *TestTerms, name: []const u8) !core.SymbolId {
        return try self.interner.intern(name, .vanilla);
    }

    fn local(self: *TestTerms, name: []const u8) !core.SymbolId {
        return try self.interner.fresh(name);
    }

    fn at(id: core.SymbolId, offset: u32) stg.Atom {
        return .{ .local = .{ .offset = offset, .name = id } };
    }

    fn num(self: *TestTerms, n: i64) !stg.Atom {
        const thunk = try self.allocator().create(value.Thunk);
        thunk.* = value.Thunk.value(.{ .number = n });
        return .{ .literal = thunk };
    }

    fn call(self: *TestTerms, callee: core.SymbolId, arguments: []const stg.Atom) !stg.Expr {
        const node = try self.allocator().create(stg.Expr.Apply);
        node.* = .{
            .callee = .{ .global = .{ .index = 0, .symbol = callee } },
            .arguments = try self.allocator().dupe(stg.Atom, arguments),
        };
        return .{ .apply = node };
    }

    fn closure(self: *TestTerms, free: []const stg.Local, parameters: []const core.SymbolId, body: stg.Expr) !*const stg.Closure {
        const node = try self.allocator().create(stg.Closure);
        node.* = .{
            .free = try self.allocator().dupe(stg.Local, free),
            .parameters = try self.allocator().dupe(core.SymbolId, parameters),
            .body = body,
        };
        return node;
    }

    fn let(self: *TestTerms, recursive: bool, bindings: []const stg.Binding, body: stg.Expr) !stg.Expr {
        const node = try self.allocator().create(stg.Expr.Let);
        node.* = .{
            .bindings = try self.allocator().dupe(stg.Binding, bindings),
            .recursive = recursive,
            .body = body,
        };
        return .{ .let = node };
    }

    fn case(self: *TestTerms, scrutinee: stg.Expr, alternatives: []const stg.Alternative) !stg.Expr {
        const node = try self.allocator().create(stg.Expr.Case);
        node.* = .{
            .scrutinee = scrutinee,
            .alternatives = try self.allocator().dupe(stg.Alternative, alternatives),
        };
        return .{ .case = node };
    }

    fn alternative(self: *TestTerms, constructor: core.SymbolId, binders: []const core.SymbolId, body: stg.Expr) !stg.Alternative {
        return .{
            .constructor = constructor,
            .tag = 0,
            .binders = try self.allocator().dupe(core.SymbolId, binders),
            .body = body,
        };
    }

    fn expectPrints(self: *TestTerms, expected: []const u8, c: *const stg.Closure) !void {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        const printer: Printer = .{ .interner = &self.interner };
        try printer.closure(c, &w.writer);
        try std.testing.expectEqualStrings(expected, w.written());
    }
};

test "a shadowing binder whose scope reads the shadowed one is primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const f = try t.global("f");
    const pair = try t.global("Pair");
    const outer = try t.local("x");
    const inner = try t.local("x");
    const rest = try t.local("_");
    const body = try t.case(.{ .atom = TestTerms.at(outer, 0) }, &.{
        try t.alternative(pair, &.{ inner, rest }, try t.call(f, &.{ TestTerms.at(outer, 0), TestTerms.at(inner, 1) })),
    });
    try t.expectPrints(
        \\{} \n {x} -> case x@0 of
        \\  Pair x' _ -> f x@0 x'@1
    , try t.closure(&.{}, &.{outer}, body));
}

test "a shadowing parameter whose body does not read the captured one is not primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("x");
    const inner = try t.local("x");
    const k = try t.local("k");
    const nested = try t.closure(&.{}, &.{inner}, .{ .atom = TestTerms.at(inner, 0) });
    const term = try t.closure(&.{}, &.{outer}, try t.let(false, &.{.{ .binder = k, .value = .{ .closure = nested } }}, .{ .atom = TestTerms.at(k, 1) }));
    try t.expectPrints(
        \\{} \n {x} ->
        \\  let k = {} \n {x} -> x@0 in
        \\  k@1
    , term);
}

test "a local that hides a referenced global is primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const text = try t.global("text");
    const shadow = try t.local("text");
    const term = try t.closure(&.{}, &.{shadow}, try t.call(text, &.{TestTerms.at(shadow, 0)}));
    try t.expectPrints("{} \\n {text'} -> text text'@0", term);
}

test "an underscore binder is never primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("_");
    const inner = try t.local("_");
    const k = try t.local("k");
    const nested = try t.closure(&.{.{ .offset = 0, .name = outer }}, &.{inner}, .{ .atom = TestTerms.at(outer, 0) });
    const term = try t.closure(&.{}, &.{outer}, try t.let(false, &.{.{ .binder = k, .value = .{ .closure = nested } }}, .{ .atom = TestTerms.at(k, 1) }));
    try t.expectPrints(
        \\{} \n {_} ->
        \\  let k = {_@0} \n {_} -> _@0 in
        \\  k@1
    , term);
}

test "sibling alternative binders of one spelling are told apart" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const pair = try t.global("Pair");
    const f = try t.global("f");
    const p = try t.local("p");
    const first = try t.local("y");
    const second = try t.local("y");
    const body = try t.case(.{ .atom = TestTerms.at(p, 0) }, &.{
        try t.alternative(pair, &.{ first, second }, try t.call(f, &.{ TestTerms.at(first, 1), TestTerms.at(second, 2) })),
    });
    try t.expectPrints(
        \\{} \n {p} -> case p@0 of
        \\  Pair y' y -> f y'@1 y@2
    , try t.closure(&.{}, &.{p}, body));
}

test "a free variable prints with the name its enclosing scope gives it" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const f = try t.global("f");
    const y = try t.local("y");
    const captured = try t.local("y");
    const k = try t.local("k");
    const nested = try t.closure(&.{.{ .offset = 0, .name = y }}, &.{captured}, try t.call(f, &.{ TestTerms.at(y, 0), TestTerms.at(captured, 1) }));
    const term = try t.closure(&.{}, &.{y}, try t.let(false, &.{.{ .binder = k, .value = .{ .closure = nested } }}, .{ .atom = TestTerms.at(k, 1) }));
    try t.expectPrints(
        \\{} \n {y} ->
        \\  let k = {y@0} \n {y'} -> f y@0 y'@1 in
        \\  k@1
    , term);
}

test "a let of several bindings puts each on its own line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const cons = try t.global("Cons");
    const nil = try t.global("Nil");
    const a = try t.local("a");
    const b = try t.local("b");
    const empty = try t.allocator().create(stg.Constructed);
    empty.* = .{ .constructor = nil, .tag = 0, .fields = &.{} };
    const one = try t.allocator().create(stg.Constructed);
    one.* = .{ .constructor = cons, .tag = 1, .fields = try t.allocator().dupe(stg.Atom, &.{ try t.num(1), TestTerms.at(a, 0) }) };
    const term = try t.closure(&.{}, &.{}, try t.let(false, &.{
        .{ .binder = a, .value = .{ .constructed = empty } },
        .{ .binder = b, .value = .{ .constructed = one } },
    }, .{ .atom = TestTerms.at(b, 1) }));
    try t.expectPrints(
        \\{} \u {} ->
        \\  let
        \\    a = Nil
        \\    b = Cons 1 a@0
        \\  in
        \\  b@1
    , term);
}

test "a letrec binding whose closure has a let body lays it out below" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const go = try t.local("go");
    const c = try t.local("c");
    const empty = try t.allocator().create(stg.Constructed);
    empty.* = .{ .constructor = nil, .tag = 0, .fields = &.{} };
    const inner = try t.closure(&.{}, &.{}, try t.let(false, &.{.{ .binder = c, .value = .{ .constructed = empty } }}, .{ .atom = TestTerms.at(c, 0) }));
    const term = try t.closure(&.{}, &.{}, try t.let(true, &.{.{ .binder = go, .value = .{ .closure = inner } }}, .{ .atom = TestTerms.at(go, 0) }));
    try t.expectPrints(
        \\{} \u {} ->
        \\  letrec
        \\    go = {} \u {} ->
        \\      let c = Nil in
        \\      c@0
        \\  in
        \\  go@0
    , term);
}

test "a negative number argument is parenthesized" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const f = try t.global("f");
    const term = try t.closure(&.{}, &.{}, try t.call(f, &.{ try t.num(-7), try t.num(1) }));
    try t.expectPrints("{} \\u {} -> f (-7) 1", term);
}

test "a scrutinee that is not flat is parenthesized across lines" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const xs = try t.local("xs");
    const inner = try t.case(.{ .atom = TestTerms.at(xs, 0) }, &.{try t.alternative(nil, &.{}, .{ .atom = TestTerms.at(xs, 0) })});
    const outer = try t.case(inner, &.{try t.alternative(nil, &.{}, .{ .atom = try t.num(0) })});
    try t.expectPrints(
        \\{} \n {xs} -> case (
        \\  case xs@0 of
        \\    Nil -> xs@0
        \\) of
        \\  Nil -> 0
    , try t.closure(&.{}, &.{xs}, outer));
}
