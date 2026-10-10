//! Renders STG-shaped terms, for tests and for reading what translation
//! produced.

const std = @import("std");
const stg = @import("terms.zig");
const core = @import("../core.zig");
const string_literal = @import("../lang/string_literal.zig");

const print_scope = core.print_scope;

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

    /// Binders that enter scope together.
    const Group = union(enum) {
        closure: *const stg.Closure,
        alternative: *const stg.Alternative,
        let: *const stg.Expr.Let,
        let_no_escape: *const stg.Expr.LetNoEscape,
        join: *const stg.Join,

        pub fn len(g: Group) usize {
            return switch (g) {
                .closure => |c| c.parameters.len,
                .alternative => |a| a.binders.len,
                .let => |l| l.bindings.len,
                .let_no_escape => |l| l.joins.len,
                .join => |j| j.parameters.len,
            };
        }

        pub fn binder(g: Group, i: usize) core.SymbolId {
            return switch (g) {
                .closure => |c| c.parameters[i],
                .alternative => |a| a.binders[i],
                .let => |l| l.bindings[i].binder,
                .let_no_escape => |l| l.joins[i].binder,
                .join => |j| j.parameters[i],
            };
        }
    };

    fn writeExpr(self: Printer, e: stg.Expr, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
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
                    try print_scope.newline(w, indent + 2);
                    try self.writeExpr(c.scrutinee, w, indent + 2, scope);
                    try print_scope.newline(w, indent);
                    try w.writeByte(')');
                }
                try w.writeAll(" of");
                for (c.alternatives) |*alternative| {
                    try print_scope.newline(w, indent + 2);
                    try w.writeAll(self.interner.spelling(alternative.constructor));
                    try self.enter(.{ .alternative = alternative }, w, indent + 2, scope);
                }
                if (c.default) |default| {
                    try print_scope.newline(w, indent + 2);
                    try w.writeAll("_ ->");
                    try self.writeAfterArrow(default, w, indent + 2, scope);
                }
            },
            .let => |let| try self.enter(.{ .let = let }, w, indent, scope),
            .let_no_escape => |let| try self.enter(.{ .let_no_escape = let }, w, indent, scope),
            .jump => |jump| {
                try w.writeAll("jump ");
                try self.writeName(jump.target.binder, w, scope);
                try self.writeArguments(jump.arguments, w, scope);
            },
        }
    }

    /// Write ` e`, or `e` on its own line at `indent + 2` when it is a `let`.
    fn writeAfterArrow(self: Printer, e: stg.Expr, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        switch (e) {
            .let, .let_no_escape => {
                try print_scope.newline(w, indent + 2);
                try self.writeExpr(e, w, indent + 2, scope);
            },
            else => {
                try w.writeByte(' ');
                try self.writeExpr(e, w, indent, scope);
            },
        }
    }

    fn writeClosure(self: Printer, c: *const stg.Closure, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        try self.enter(.{ .closure = c }, w, indent, scope);
    }

    fn writeAllocation(self: Printer, a: stg.Allocation, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        switch (a) {
            .closure => |c| try self.writeClosure(c, w, indent, scope),
            .constructed => |c| {
                try w.writeAll(self.interner.spelling(c.constructor));
                try self.writeArguments(c.fields, w, scope);
            },
        }
    }

    /// Bring the binders of `g` into scope, then write what they scope.
    fn enter(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        try print_scope.enter(self, g, 0, w, indent, scope, groupCaptures, writeScoped);
    }

    fn writeScoped(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        switch (g) {
            .closure => |c| {
                const enclosing = outside(scope, c.parameters.len);
                try w.writeByte('{');
                for (c.free, 0..) |capture, i| {
                    if (i > 0) try w.writeByte(',');
                    try self.writeLocal(capture, w, enclosing);
                }
                try w.writeAll("} ");
                try w.writeAll(if (c.parameters.len == 0) "\\u " else "\\n ");
                try self.writeParameters(c.parameters, w, scope);
                try w.writeAll(" ->");
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
                        try print_scope.newline(w, indent + 2);
                        try self.writeName(binding.binder, w, scope);
                        try w.writeAll(" = ");
                        try self.writeAllocation(binding.value, w, indent + 2, scope);
                    }
                    try print_scope.newline(w, indent);
                    try w.writeAll("in");
                }
                try print_scope.newline(w, indent);
                try self.writeExpr(let.body, w, indent, scope);
            },
            .let_no_escape => |let| {
                const keyword = if (let.recursive) "letrec-no-escape" else "let-no-escape";
                // A join point's body sees the group only when it is recursive.
                const body_scope = if (let.recursive) scope else outside(scope, let.joins.len);
                if (let.joins.len == 1 and isFlat(let.joins[0].body)) {
                    try w.print("{s} ", .{keyword});
                    try self.writeName(let.joins[0].binder, w, scope);
                    try self.enter(.{ .join = &let.joins[0] }, w, indent, body_scope);
                    try w.writeAll(" in");
                } else {
                    try w.writeAll(keyword);
                    for (let.joins) |*join| {
                        try print_scope.newline(w, indent + 2);
                        try self.writeName(join.binder, w, scope);
                        try self.enter(.{ .join = join }, w, indent + 2, body_scope);
                    }
                    try print_scope.newline(w, indent);
                    try w.writeAll("in");
                }
                try print_scope.newline(w, indent);
                try self.writeExpr(let.body, w, indent, scope);
            },
            .join => |join| {
                try w.writeByte(' ');
                try self.writeParameters(join.parameters, w, scope);
                try w.writeAll(" ->");
                try self.writeAfterArrow(join.body, w, indent, scope);
            },
        }
    }

    /// Write `{p_1,...,p_n}`.
    fn writeParameters(self: Printer, parameters: []const core.SymbolId, w: *std.Io.Writer, scope: ?*print_scope.Scope) Error!void {
        try w.writeByte('{');
        for (parameters, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try self.writeName(p, w, scope);
        }
        try w.writeByte('}');
    }

    /// The scope outside the innermost `n` nodes.
    fn outside(scope: ?*print_scope.Scope, n: usize) ?*print_scope.Scope {
        var node = scope;
        for (0..n) |_| node = node.?.parent;
        return node;
    }

    fn groupCaptures(self: Printer, g: Group, binder: core.SymbolId, spelling: []const u8, primes: u32, scope: ?*print_scope.Scope) bool {
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
            .let_no_escape => |let| self.joinsCapture(let, target),
            .join => |join| self.captures(join.body, target),
        };
    }

    fn joinsCapture(self: Printer, let: *const stg.Expr.LetNoEscape, target: Target) bool {
        for (let.joins) |join| {
            if (self.captures(join.body, target)) return true;
        }
        return self.captures(let.body, target);
    }

    /// A printed name a reference must not resolve to: `spelling` with
    /// `primes` primes, belonging to any symbol other than `binder`.
    const Target = struct {
        binder: core.SymbolId,
        spelling: []const u8,
        primes: u32,
        scope: ?*print_scope.Scope,
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
                if (c.default) |default| return self.captures(default, target);
                return false;
            },
            .let => |let| {
                for (let.bindings) |binding| {
                    if (self.allocationCaptures(binding.value, target)) return true;
                }
                return self.captures(let.body, target);
            },
            .let_no_escape => |let| self.joinsCapture(let, target),
            .jump => |jump| self.symbolCaptures(jump.target.binder, target) or
                self.atomsCapture(jump.arguments, target),
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
            print_scope.outerPrimes(self.interner, id, target.scope) == target.primes;
    }

    fn writeName(self: Printer, id: core.SymbolId, w: *std.Io.Writer, scope: ?*print_scope.Scope) Error!void {
        try print_scope.writeName(self.interner, id, w, scope);
    }

    fn writeLocal(self: Printer, local: stg.Local, w: *std.Io.Writer, scope: ?*print_scope.Scope) Error!void {
        try self.writeName(local.name, w, scope);
        try w.print("@{d}", .{local.offset});
    }

    const Position = enum { top, argument };

    fn writeAtom(self: Printer, a: stg.Atom, w: *std.Io.Writer, position: Position, scope: ?*print_scope.Scope) Error!void {
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

    fn writeArguments(self: Printer, list: []const stg.Atom, w: *std.Io.Writer, scope: ?*print_scope.Scope) Error!void {
        for (list) |a| {
            try w.writeByte(' ');
            try self.writeAtom(a, w, .argument, scope);
        }
    }

    fn isFlat(e: stg.Expr) bool {
        return switch (e) {
            .atom, .apply, .constructed, .primitive, .jump => true,
            .case, .let, .let_no_escape => false,
        };
    }

    fn isAllocationFlat(a: stg.Allocation) bool {
        return switch (a) {
            .closure => |c| isFlat(c.body),
            .constructed => true,
        };
    }
};

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
        return try self.interner.intern(.prim, name, .vanilla);
    }

    fn local(self: *TestTerms, name: []const u8) !core.SymbolId {
        return try self.interner.fresh(name);
    }

    fn at(id: core.SymbolId, offset: u32) stg.Atom {
        return .{ .local = .{ .offset = offset, .name = id } };
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

    fn expectPrints(self: *TestTerms, expected: []const u8, c: *const stg.Closure) !void {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        const printer: Printer = .{ .interner = &self.interner };
        try printer.closure(c, &w.writer);
        try std.testing.expectEqualStrings(expected, w.written());
    }
};

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
