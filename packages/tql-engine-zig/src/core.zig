//! Core terms.
//!
//! ```
//! expr ::= symbol
//!        | literal
//!        | \x -> expr
//!        | expr_1 expr_2
//!        | case expr of { C x_1 .. x_n -> expr; ... }
//!        | letrec { x_1 = expr_1; ...; x_i = expr_i; } in expr_N
//!        | bind x <- expr_1 in expr_2
//! ```

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const string_literal = @import("lang/string_literal.zig");

pub const symbols = @import("core/symbols.zig");
pub const details = @import("core/details.zig");
pub const env = @import("core/env.zig");
pub const types = @import("core/types.zig");
pub const datatypes = @import("core/datatypes.zig");
const program = @import("core/program.zig");

/// A linked program, and what every stage after desugaring reads.
pub const Program = program.Program;
pub const printProgram = program.printProgram;

pub const Synthesized = details.Synthesized;
pub const PrimOp = details.PrimOp;
pub const Scalar = details.Scalar;

pub const SymbolId = symbols.SymbolId;
pub const SymbolTable = symbols.SymbolTable;
pub const Interner = symbols.Interner;
pub const InsertError = symbols.InsertError;

const Allocator = std.mem.Allocator;

// ============================================================================
//                              Terms
// ============================================================================

pub const Term = struct {
    kind: Kind,
    /// Where this term came from, before desugaring.
    // IMPROVE: parameterize this
    span: diagnostic.Span,

    pub const Kind = union(enum) {
        symbol: SymbolId,
        literal: Literal,
        lambda: *const Lambda,
        apply: *const Apply,
        case: *const Case,
        letrec: *const Letrec,
        bind: *const Bind,
    };
};

pub const Literal = union(enum) {
    number: i64,
    string: []const u8,
    /// The pattern as written. Desugaring has checked that it compiles.
    regex: []const u8,
    /// A node kind, resolved against the target grammar during desugaring.
    kind: Kind,

    pub const Kind = struct { name: []const u8, id: u16 };
};

pub const Lambda = struct {
    parameter: SymbolId,
    body: Term,
};

pub const Apply = struct {
    function: Term,
    argument: Term,
};

pub const Case = struct {
    scrutinee: Term,
    alternatives: []const Alternative,

    pub const Alternative = struct {
        constructor: SymbolId,
        binders: []const SymbolId,
        body: Term,
    };
};

pub const Letrec = struct {
    bindings: []const Binding,
    body: Term,

    pub const Binding = struct {
        name: SymbolId,
        value: Term,
    };
};

pub const Bind = struct {
    name: SymbolId,
    value: Term,
    body: Term,
};

/// A top-level definition.
pub const Definition = struct {
    symbol: SymbolId,
    body: Term,
    span: diagnostic.Span,
};

/// Builds the compound terms into an arena. Every term outlives the builder.
pub const Builder = struct {
    allocator: Allocator,

    pub fn dupe(self: Builder, text: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, text);
    }

    pub fn slice(self: Builder, comptime T: type, n: usize) ![]T {
        return try self.allocator.alloc(T, n);
    }

    pub fn dupeSlice(self: Builder, comptime T: type, values: []const T) ![]T {
        return try self.allocator.dupe(T, values);
    }

    pub fn join(self: Builder, separator: []const u8, parts: []const []const u8) ![]const u8 {
        return try std.mem.join(self.allocator, separator, parts);
    }

    pub fn print(self: Builder, comptime format: []const u8, args: anytype) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, format, args);
    }

    pub fn symbol(self: Builder, id: SymbolId, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .symbol = id }, .span = span };
    }

    pub fn literal(self: Builder, value: Literal, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .literal = value }, .span = span };
    }
    pub fn lambda(self: Builder, parameter: SymbolId, body: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Lambda);
        node.* = .{ .parameter = parameter, .body = body };
        return .{ .kind = .{ .lambda = node }, .span = span };
    }

    pub fn apply(self: Builder, function: Term, argument: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Apply);
        node.* = .{ .function = function, .argument = argument };
        return .{ .kind = .{ .apply = node }, .span = span };
    }

    /// `f a b` as `(f a) b`, sharing one span.
    pub fn applyMany(self: Builder, function: Term, arguments: []const Term, span: diagnostic.Span) !Term {
        var result = function;
        for (arguments) |argument| result = try self.apply(result, argument, span);
        return result;
    }

    pub fn case(
        self: Builder,
        scrutinee: Term,
        alternatives: []const Case.Alternative,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Case);
        node.* = .{ .scrutinee = scrutinee, .alternatives = alternatives };
        return .{ .kind = .{ .case = node }, .span = span };
    }

    pub fn letrec(
        self: Builder,
        bindings: []const Letrec.Binding,
        body: Term,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Letrec);
        node.* = .{ .bindings = bindings, .body = body };
        return .{ .kind = .{ .letrec = node }, .span = span };
    }

    pub fn bind(self: Builder, name: SymbolId, value: Term, body: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Bind);
        node.* = .{ .name = name, .value = value, .body = body };
        return .{ .kind = .{ .bind = node }, .span = span };
    }
};

/// Lays a term out across lines by its structure. A term without `case`,
/// `letrec` or `bind` prints on one line.
///
/// A binder prints with primes appended when its scope references another
/// symbol of the same printed name.
pub const Printer = struct {
    interner: *const Interner,

    const Error = std.Io.Writer.Error;

    pub fn term(self: Printer, t: Term, w: *std.Io.Writer) Error!void {
        try self.write(t, w, .top, 0, null);
    }

    /// Writes `name = body`.
    pub fn definition(self: Printer, name: SymbolId, body: Term, w: *std.Io.Writer) Error!void {
        try w.print("{s} =", .{self.interner.spelling(name)});
        try self.writeAfterArrow(body, w, 0, null);
    }

    /// Where a term sits, which decides whether it needs parentheses.
    const Position = enum {
        /// Nothing binds tighter; never parenthesized.
        top,
        /// Left of an application: only an application may sit here bare.
        callee,
        /// Right of an application, or an `if` operand.
        operand,
    };

    /// A local in scope and the primes it prints with.
    const Scope = struct {
        symbol: SymbolId,
        primes: u32,
        parent: ?*Scope,
    };

    /// Binders that enter scope together.
    const Group = union(enum) {
        lambda: *const Lambda,
        alternative: *const Case.Alternative,
        letrec: *const Letrec,
        bind: *const Bind,

        fn len(g: Group) usize {
            return switch (g) {
                .lambda, .bind => 1,
                .alternative => |a| a.binders.len,
                .letrec => |l| l.bindings.len,
            };
        }

        fn binder(g: Group, i: usize) SymbolId {
            return switch (g) {
                .lambda => |l| l.parameter,
                .alternative => |a| a.binders[i],
                .letrec => |l| l.bindings[i].name,
                .bind => |b| b.name,
            };
        }
    };

    fn write(
        self: Printer,
        t: Term,
        w: *std.Io.Writer,
        position: Position,
        indent: usize,
        scope: ?*Scope,
    ) Error!void {
        const wrap = switch (t.kind) {
            .symbol => false,
            .literal => |value| position == .operand and value == .number and value.number < 0,
            .apply => position == .operand,
            .lambda, .case, .letrec, .bind => position != .top,
        };
        if (wrap) {
            try self.writeParenthesized(t, w, indent, scope);
        } else {
            try self.writeBare(t, w, indent, scope);
        }
    }

    fn writeParenthesized(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        try w.writeByte('(');
        if (isFlat(t)) {
            try self.writeBare(t, w, indent, scope);
        } else {
            try newline(w, indent + 2);
            try self.writeBare(t, w, indent + 2, scope);
            try newline(w, indent);
        }
        try w.writeByte(')');
    }

    /// Writes ` t`, or `t` on its own line at `indent + 2` when it is a
    /// `letrec` or `bind`.
    fn writeAfterArrow(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (t.kind) {
            .letrec, .bind => {
                try newline(w, indent + 2);
                try self.write(t, w, .top, indent + 2, scope);
            },
            else => {
                try w.writeByte(' ');
                try self.write(t, w, .top, indent, scope);
            },
        }
    }

    fn writeBare(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (t.kind) {
            .symbol => |id| try self.writeName(id, w, scope),
            .literal => |value| try writeLiteral(value, w),
            .lambda => |l| try self.enter(.{ .lambda = l }, 0, w, indent, scope),
            .apply => |a| {
                try self.write(a.function, w, .callee, indent, scope);
                try w.writeByte(' ');
                try self.write(a.argument, w, .operand, indent, scope);
            },
            .case => |c| {
                try w.writeAll("case ");
                if (isFlat(c.scrutinee)) {
                    try self.write(c.scrutinee, w, .top, indent, scope);
                } else {
                    try self.writeParenthesized(c.scrutinee, w, indent, scope);
                }
                try w.writeAll(" of");
                for (c.alternatives) |*alternative| {
                    try newline(w, indent + 2);
                    try w.writeAll(self.interner.spelling(alternative.constructor));
                    try self.enter(.{ .alternative = alternative }, 0, w, indent + 2, scope);
                }
            },
            .letrec => |l| try self.enter(.{ .letrec = l }, 0, w, indent, scope),
            .bind => |b| try self.enter(.{ .bind = b }, 0, w, indent, scope),
        }
    }

    /// Brings binders `i..` of `g` into scope, then writes what they scope.
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

    fn primesFor(self: Printer, g: Group, binder: SymbolId, scope: ?*Scope) u32 {
        const spelling = self.interner.spelling(binder);
        if (std.mem.eql(u8, spelling, "_")) return 0;
        var primes: u32 = 0;
        while (self.groupCaptures(g, binder, spelling, primes, scope)) primes += 1;
        return primes;
    }

    fn groupCaptures(self: Printer, g: Group, binder: SymbolId, spelling: []const u8, primes: u32, scope: ?*Scope) bool {
        return switch (g) {
            .lambda => |l| self.captures(l.body, binder, spelling, primes, scope),
            .alternative => |a| self.captures(a.body, binder, spelling, primes, scope),
            .bind => |b| self.captures(b.body, binder, spelling, primes, scope),
            .letrec => |l| {
                for (l.bindings) |b| {
                    if (self.captures(b.value, binder, spelling, primes, scope)) return true;
                }
                return self.captures(l.body, binder, spelling, primes, scope);
            },
        };
    }

    /// Whether `t` references a symbol other than `binder`, bound outside
    /// `t`, that prints as `spelling` with `primes` primes.
    fn captures(self: Printer, t: Term, binder: SymbolId, spelling: []const u8, primes: u32, scope: ?*Scope) bool {
        return switch (t.kind) {
            .symbol => |id| id != binder and
                std.mem.eql(u8, self.interner.spelling(id), spelling) and
                self.outerPrimes(id, scope) == primes,
            .literal => false,
            .lambda => |l| self.captures(l.body, binder, spelling, primes, scope),
            .apply => |a| self.captures(a.function, binder, spelling, primes, scope) or
                self.captures(a.argument, binder, spelling, primes, scope),
            .case => |c| {
                if (self.captures(c.scrutinee, binder, spelling, primes, scope)) return true;
                for (c.alternatives) |alternative| {
                    if (self.captures(alternative.body, binder, spelling, primes, scope)) return true;
                }
                return false;
            },
            .letrec => |l| {
                for (l.bindings) |b| {
                    if (self.captures(b.value, binder, spelling, primes, scope)) return true;
                }
                return self.captures(l.body, binder, spelling, primes, scope);
            },
            .bind => |b| self.captures(b.value, binder, spelling, primes, scope) or
                self.captures(b.body, binder, spelling, primes, scope),
        };
    }

    /// The primes `id` prints with if it is in scope or a global, else null.
    fn outerPrimes(self: Printer, id: SymbolId, scope: ?*Scope) ?u32 {
        var node = scope;
        while (node) |n| : (node = n.parent) {
            if (n.symbol == id) return n.primes;
        }
        const global = self.interner.by_spelling.get(self.interner.spelling(id)) orelse return null;
        return if (global == id) 0 else null;
    }

    fn writeScoped(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*Scope) Error!void {
        switch (g) {
            .lambda => |l| {
                try w.writeByte('\\');
                try self.writeName(l.parameter, w, scope);
                try w.writeAll(" ->");
                try self.writeAfterArrow(l.body, w, indent, scope);
            },
            .alternative => |a| {
                for (a.binders) |binder| {
                    try w.writeByte(' ');
                    try self.writeName(binder, w, scope);
                }
                try w.writeAll(" ->");
                try self.writeAfterArrow(a.body, w, indent, scope);
            },
            .letrec => |l| {
                if (l.bindings.len == 1 and isFlat(l.bindings[0].value)) {
                    try w.writeAll("letrec ");
                    try self.writeName(l.bindings[0].name, w, scope);
                    try w.writeAll(" = ");
                    try self.write(l.bindings[0].value, w, .top, indent, scope);
                    try w.writeAll(" in");
                } else {
                    try w.writeAll("letrec");
                    for (l.bindings) |b| {
                        try newline(w, indent + 2);
                        try self.writeName(b.name, w, scope);
                        try w.writeAll(" =");
                        try self.writeAfterArrow(b.value, w, indent + 2, scope);
                    }
                    try newline(w, indent);
                    try w.writeAll("in");
                }
                try newline(w, indent);
                try self.write(l.body, w, .top, indent, scope);
            },
            .bind => |b| {
                try w.writeAll("bind ");
                try self.writeName(b.name, w, scope);
                try w.writeAll(" <-");
                const outer = scope.?.parent;
                try self.writeAfterArrow(b.value, w, indent, outer);
                if (isFlat(b.value)) {
                    try w.writeAll(" in");
                } else {
                    try newline(w, indent);
                    try w.writeAll("in");
                }
                try newline(w, indent);
                try self.write(b.body, w, .top, indent, scope);
            },
        }
    }

    fn writeName(self: Printer, id: SymbolId, w: *std.Io.Writer, scope: ?*Scope) Error!void {
        try w.writeAll(self.interner.spelling(id));
        try w.splatByteAll('\'', self.outerPrimes(id, scope) orelse 0);
    }

    fn newline(w: *std.Io.Writer, indent: usize) Error!void {
        try w.writeByte('\n');
        try w.splatByteAll(' ', indent);
    }

    fn isFlat(t: Term) bool {
        return switch (t.kind) {
            .symbol, .literal => true,
            .lambda => |l| isFlat(l.body),
            .apply => |a| isFlat(a.function) and isFlat(a.argument),
            .case, .letrec, .bind => false,
        };
    }

    fn writeLiteral(value: Literal, w: *std.Io.Writer) Error!void {
        switch (value) {
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("\"{f}\"", .{string_literal.fmt(s)}),
            .regex => |pattern| try w.print("r\"{s}\"", .{pattern}),
            .kind => |k| try w.print(":{s}", .{k.name}),
        }
    }
};

const TestTerms = struct {
    arena: std.heap.ArenaAllocator,
    interner: Interner,

    const span = diagnostic.Span.unknown;

    fn init(self: *TestTerms) void {
        self.arena = .init(std.testing.allocator);
        self.interner = .init(self.arena.allocator());
    }

    fn deinit(self: *TestTerms) void {
        self.arena.deinit();
    }

    fn b(self: *TestTerms) Builder {
        return .{ .allocator = self.arena.allocator() };
    }

    fn global(self: *TestTerms, name: []const u8) !SymbolId {
        return try self.interner.intern(name, .vanilla);
    }

    fn local(self: *TestTerms, name: []const u8) !SymbolId {
        return try self.interner.fresh(name);
    }

    fn sym(self: *TestTerms, id: SymbolId) Term {
        return self.b().symbol(id, span);
    }

    fn num(self: *TestTerms, n: i64) Term {
        return self.b().literal(.{ .number = n }, span);
    }

    fn lam(self: *TestTerms, parameter: SymbolId, body: Term) !Term {
        return try self.b().lambda(parameter, body, span);
    }

    fn app(self: *TestTerms, function: Term, arguments: []const Term) !Term {
        return try self.b().applyMany(function, arguments, span);
    }

    fn case_(self: *TestTerms, scrutinee: Term, alternatives: []const Case.Alternative) !Term {
        return try self.b().case(scrutinee, try self.b().dupeSlice(Case.Alternative, alternatives), span);
    }

    fn alt(self: *TestTerms, constructor: SymbolId, binders: []const SymbolId, body: Term) !Case.Alternative {
        return .{ .constructor = constructor, .binders = try self.b().dupeSlice(SymbolId, binders), .body = body };
    }

    fn letrec(self: *TestTerms, bindings: []const Letrec.Binding, body: Term) !Term {
        return try self.b().letrec(try self.b().dupeSlice(Letrec.Binding, bindings), body, span);
    }

    fn bind(self: *TestTerms, name: SymbolId, value: Term, body: Term) !Term {
        return try self.b().bind(name, value, body, span);
    }

    fn expectPrints(self: *TestTerms, expected: []const u8, t: Term) !void {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        const printer: Printer = .{ .interner = &self.interner };
        try printer.term(t, &w.writer);
        try std.testing.expectEqualStrings(expected, w.written());
    }

    fn expectDefinitionPrints(self: *TestTerms, expected: []const u8, name: SymbolId, body: Term) !void {
        var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer w.deinit();
        const printer: Printer = .{ .interner = &self.interner };
        try printer.definition(name, body, &w.writer);
        try std.testing.expectEqualStrings(expected, w.written());
    }
};

test "a shadowing binder whose scope references the shadowed one is primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("x");
    const inner = try t.local("x");
    const term = try t.lam(outer, try t.lam(inner, try t.app(t.sym(outer), &.{t.sym(inner)})));
    try t.expectPrints("\\x -> \\x' -> x x'", term);
}

test "a shadowing binder whose scope does not reference the shadowed one is not primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("x");
    const inner = try t.local("x");
    const term = try t.lam(outer, try t.lam(inner, t.sym(inner)));
    try t.expectPrints("\\x -> \\x -> x", term);
}

test "a local that hides a referenced global is primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const text = try t.global("text");
    const local = try t.local("text");
    const term = try t.lam(local, try t.app(t.sym(text), &.{t.sym(local)}));
    try t.expectPrints("\\text' -> text text'", term);
}

test "each level of shadowing adds a prime" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const x0 = try t.local("x");
    const x1 = try t.local("x");
    const x2 = try t.local("x");
    const body = try t.app(t.sym(x0), &.{ t.sym(x1), t.sym(x2) });
    const term = try t.lam(x0, try t.lam(x1, try t.lam(x2, body)));
    try t.expectPrints("\\x -> \\x' -> \\x'' -> x x' x''", term);
}

test "an underscore binder is never primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("_");
    const inner = try t.local("_");
    const term = try t.lam(outer, try t.lam(inner, t.sym(outer)));
    try t.expectPrints("\\_ -> \\_ -> _", term);
}

test "sibling binders of one spelling are told apart" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const cons = try t.global("Cons");
    const xs = try t.local("xs");
    const first = try t.local("y");
    const second = try t.local("y");
    const term = try t.lam(xs, try t.case_(t.sym(xs), &.{
        try t.alt(cons, &.{ first, second }, try t.app(t.sym(first), &.{t.sym(second)})),
    }));
    try t.expectPrints(
        \\\xs -> case xs of
        \\  Cons y' y -> y' y
    , term);
}

test "a bind's value is outside the scope of its name" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("x");
    const inner = try t.local("x");
    const term = try t.lam(outer, try t.bind(inner, t.sym(outer), t.sym(inner)));
    try t.expectPrints(
        \\\x ->
        \\  bind x <- x in
        \\  x
    , term);
}

test "a bind whose body references the shadowed name is primed" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("x");
    const inner = try t.local("x");
    const term = try t.lam(outer, try t.bind(inner, t.sym(outer), try t.app(t.sym(outer), &.{t.sym(inner)})));
    try t.expectPrints(
        \\\x ->
        \\  bind x' <- x in
        \\  x x'
    , term);
}

test "a letrec binding is in scope in its siblings' values" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const outer = try t.local("a");
    const inner = try t.local("a");
    const other = try t.local("b");
    const term = try t.lam(outer, try t.letrec(&.{
        .{ .name = inner, .value = t.num(1) },
        .{ .name = other, .value = try t.app(t.sym(outer), &.{t.sym(inner)}) },
    }, t.sym(other)));
    try t.expectPrints(
        \\\a ->
        \\  letrec
        \\    a' = 1
        \\    b = a a'
        \\  in
        \\  b
    , term);
}

test "a negative number argument is parenthesized" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const f = try t.global("f");
    const term = try t.app(t.sym(f), &.{ t.num(-7), t.num(1) });
    try t.expectPrints("f (-7) 1", term);
}

test "a term without case, letrec or bind prints on one line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const f = try t.global("f");
    const x = try t.local("x");
    const y = try t.local("y");
    const term = try t.lam(y, try t.app(t.sym(f), &.{ try t.lam(x, t.sym(x)), try t.app(t.sym(f), &.{t.sym(y)}) }));
    try t.expectPrints("\\y -> f (\\x -> x) (f y)", term);
}

test "case alternatives each take a line, and a case alternative body hangs" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const cons = try t.global("Cons");
    const xs = try t.local("xs");
    const h = try t.local("h");
    const rest = try t.local("t");
    const inner = try t.case_(t.sym(rest), &.{
        try t.alt(nil, &.{}, t.sym(h)),
        try t.alt(cons, &.{ try t.local("_"), try t.local("_") }, t.num(0)),
    });
    const term = try t.case_(t.sym(xs), &.{
        try t.alt(nil, &.{}, t.num(0)),
        try t.alt(cons, &.{ h, rest }, inner),
    });
    try t.expectPrints(
        \\case xs of
        \\  Nil -> 0
        \\  Cons h t -> case t of
        \\    Nil -> h
        \\    Cons _ _ -> 0
    , term);
}

test "a case alternative whose body is a bind starts it on a new line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const xs = try t.local("xs");
    const y = try t.local("y");
    const term = try t.case_(t.sym(xs), &.{
        try t.alt(nil, &.{}, try t.bind(y, t.sym(xs), t.sym(y))),
    });
    try t.expectPrints(
        \\case xs of
        \\  Nil ->
        \\    bind y <- xs in
        \\    y
    , term);
}

test "a letrec of one flat binding takes one line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const main = try t.global("main");
    const f = try t.global("f");
    const a = try t.local("a");
    const term = try t.letrec(&.{.{ .name = a, .value = try t.app(t.sym(f), &.{t.num(1)}) }}, t.sym(a));
    try t.expectDefinitionPrints(
        \\main =
        \\  letrec a = f 1 in
        \\  a
    , main, term);
}

test "a letrec binding whose value is not flat is laid out like several" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const a = try t.local("a");
    const n = try t.local("n");
    const value = try t.lam(n, try t.case_(t.sym(n), &.{try t.alt(nil, &.{}, t.num(0))}));
    const term = try t.letrec(&.{.{ .name = a, .value = value }}, t.sym(a));
    try t.expectPrints(
        \\letrec
        \\  a = \n -> case n of
        \\    Nil -> 0
        \\in
        \\a
    , term);
}

test "a bind whose value is not flat ends with in on its own line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const xs = try t.local("xs");
    const y = try t.local("y");
    const value = try t.case_(t.sym(xs), &.{try t.alt(nil, &.{}, t.num(0))});
    const term = try t.lam(xs, try t.bind(y, value, t.sym(y)));
    try t.expectPrints(
        \\\xs ->
        \\  bind y <- case xs of
        \\    Nil -> 0
        \\  in
        \\  y
    , term);
}

test "an operand that is not flat is parenthesized across lines" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const main = try t.global("main");
    const f = try t.global("f");
    const nil = try t.global("Nil");
    const xs = try t.local("xs");
    const argument = try t.case_(t.sym(xs), &.{try t.alt(nil, &.{}, t.num(0))});
    const term = try t.lam(xs, try t.app(t.sym(f), &.{ argument, t.num(1) }));
    try t.expectDefinitionPrints(
        \\main = \xs -> f (
        \\  case xs of
        \\    Nil -> 0
        \\) 1
    , main, term);
}

test "a scrutinee that is not flat is parenthesized across lines" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const nil = try t.global("Nil");
    const xs = try t.local("xs");
    const inner = try t.case_(t.sym(xs), &.{try t.alt(nil, &.{}, t.sym(xs))});
    const term = try t.case_(inner, &.{try t.alt(nil, &.{}, t.num(0))});
    try t.expectPrints(
        \\case (
        \\  case xs of
        \\    Nil -> xs
        \\) of
        \\  Nil -> 0
    , term);
}

test "a lambda whose body is a bind starts it on a new line" {
    var t: TestTerms = undefined;
    t.init();
    defer t.deinit();
    const main = try t.global("main");
    const f = try t.global("f");
    const root = try t.local("root");
    const c = try t.local("c");
    const n = try t.local("n");
    const term = try t.lam(root, try t.bind(
        c,
        try t.app(t.sym(f), &.{t.sym(root)}),
        try t.bind(n, try t.app(t.sym(f), &.{t.sym(c)}), t.sym(n)),
    ));
    try t.expectDefinitionPrints(
        \\main = \root ->
        \\  bind c <- f root in
        \\  bind n <- f c in
        \\  n
    , main, term);
}
