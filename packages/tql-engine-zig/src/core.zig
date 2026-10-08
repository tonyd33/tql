//! Core terms.
//!
//! ```
//! expr ::= symbol
//!        | literal
//!        | \x -> expr
//!        | expr_1 expr_2
//!        | case expr of { C x_1 .. x_n -> expr; ... }
//!        | let x = expr_1 in expr_2
//!        | letrec { x_1 = expr_1; ...; x_i = expr_i; } in expr_N
//! ```

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const string_literal = @import("lang/string_literal.zig");

pub const symbols = @import("core/symbols.zig");
pub const details = @import("core/details.zig");
pub const env = @import("core/env.zig");
pub const types = @import("core/types.zig");
pub const datatypes = @import("core/datatypes.zig");
pub const print_scope = @import("core/print_scope.zig");
pub const free = @import("core/free.zig");
pub const components = @import("core/components.zig");
pub const test_support = @import("core/test_support.zig");
const program = @import("core/program.zig");

/// A linked program, and what every stage after desugaring reads.
pub const Program = program.Program;
pub const printProgram = program.printProgram;

pub const Synthesized = details.Synthesized;
pub const PrimOp = details.PrimOp;
pub const Operation = details.Operation;
pub const Scalar = details.Scalar;

pub const SymbolId = symbols.SymbolId;
pub const ModuleId = symbols.ModuleId;
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
        let: *const Let,
        letrec: *const Letrec,
    };

    /// How many lambdas the term starts with.
    pub fn arity(t: Term) usize {
        var count: usize = 0;
        var body = t;
        while (body.kind == .lambda) : (body = body.kind.lambda.body) count += 1;
        return count;
    }

    /// The function at the head of an application spine, or the term itself.
    pub fn head(t: Term) Term {
        var result = t;
        while (result.kind == .apply) result = result.kind.apply.function;
        return result;
    }
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

/// `name` is in scope in `body` and not in `value`.
pub const Let = struct {
    name: SymbolId,
    value: Term,
    body: Term,
};

pub const Letrec = struct {
    bindings: []const Binding,
    body: Term,

    pub const Binding = struct {
        name: SymbolId,
        value: Term,
    };
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

    pub fn let(
        self: Builder,
        name: SymbolId,
        value: Term,
        body: Term,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Let);
        node.* = .{ .name = name, .value = value, .body = body };
        return .{ .kind = .{ .let = node }, .span = span };
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
};

/// Lay a term out across lines by its structure. A term without `case`, `let`
/// or `letrec` prints on one line.
///
/// A binder prints with primes appended when its scope references another
/// symbol of the same printed name.
pub const Printer = struct {
    interner: *const Interner,

    const Error = std.Io.Writer.Error;

    pub fn term(self: Printer, t: Term, w: *std.Io.Writer) Error!void {
        try self.write(t, w, .top, 0, null);
    }

    pub fn definition(self: Printer, name: SymbolId, body: Term, w: *std.Io.Writer) Error!void {
        try w.print("{s} =", .{self.interner.spelling(name)});
        try self.writeAfterArrow(body, w, 0, null);
    }

    /// Write `name = term` for each definition in `list`, one per line.
    pub fn definitions(self: Printer, list: []const Definition, w: *std.Io.Writer) Error!void {
        for (list, 0..) |d, i| {
            if (i > 0) try w.writeByte('\n');
            try self.definition(d.symbol, d.body, w);
        }
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

    /// Binders that enter scope together.
    const Group = union(enum) {
        lambda: *const Lambda,
        alternative: *const Case.Alternative,
        let: *const Let,
        letrec: *const Letrec,

        pub fn len(g: Group) usize {
            return switch (g) {
                .lambda, .let => 1,
                .alternative => |a| a.binders.len,
                .letrec => |l| l.bindings.len,
            };
        }

        pub fn binder(g: Group, i: usize) SymbolId {
            return switch (g) {
                .lambda => |l| l.parameter,
                .alternative => |a| a.binders[i],
                .let => |l| l.name,
                .letrec => |l| l.bindings[i].name,
            };
        }
    };

    fn write(
        self: Printer,
        t: Term,
        w: *std.Io.Writer,
        position: Position,
        indent: usize,
        scope: ?*print_scope.Scope,
    ) Error!void {
        const wrap = switch (t.kind) {
            .symbol => false,
            .literal => |value| position == .operand and value == .number and value.number < 0,
            .apply => position == .operand,
            .lambda, .case, .let, .letrec => position != .top,
        };
        if (wrap) {
            try self.writeParenthesized(t, w, indent, scope);
        } else {
            try self.writeBare(t, w, indent, scope);
        }
    }

    fn writeParenthesized(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        try w.writeByte('(');
        if (isFlat(t)) {
            try self.writeBare(t, w, indent, scope);
        } else {
            try print_scope.newline(w, indent + 2);
            try self.writeBare(t, w, indent + 2, scope);
            try print_scope.newline(w, indent);
        }
        try w.writeByte(')');
    }

    /// Write ` t`, or `t` on its own line at `indent + 2` when it is a `let`
    /// or `letrec`.
    fn writeAfterArrow(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        switch (t.kind) {
            .let, .letrec => {
                try print_scope.newline(w, indent + 2);
                try self.write(t, w, .top, indent + 2, scope);
            },
            else => {
                try w.writeByte(' ');
                try self.write(t, w, .top, indent, scope);
            },
        }
    }

    fn writeBare(self: Printer, t: Term, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        switch (t.kind) {
            .symbol => |id| try self.writeName(id, w, scope),
            .literal => |value| try writeLiteral(value, w),
            .lambda => |l| try self.enter(.{ .lambda = l }, w, indent, scope),
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
                    try print_scope.newline(w, indent + 2);
                    try w.writeAll(self.interner.spelling(alternative.constructor));
                    try self.enter(.{ .alternative = alternative }, w, indent + 2, scope);
                }
            },
            .let => |l| try self.enter(.{ .let = l }, w, indent, scope),
            .letrec => |l| try self.enter(.{ .letrec = l }, w, indent, scope),
        }
    }

    /// Bring the binders of `g` into scope, then write what they scope.
    fn enter(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
        try print_scope.enter(self, g, 0, w, indent, scope, groupCaptures, writeScoped);
    }

    fn groupCaptures(self: Printer, g: Group, binder: SymbolId, spelling: []const u8, primes: u32, scope: ?*print_scope.Scope) bool {
        return switch (g) {
            .lambda => |l| self.captures(l.body, binder, spelling, primes, scope),
            .alternative => |a| self.captures(a.body, binder, spelling, primes, scope),
            .let => |l| self.captures(l.body, binder, spelling, primes, scope),
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
    fn captures(self: Printer, t: Term, binder: SymbolId, spelling: []const u8, primes: u32, scope: ?*print_scope.Scope) bool {
        return switch (t.kind) {
            .symbol => |id| id != binder and
                std.mem.eql(u8, self.interner.spelling(id), spelling) and
                print_scope.outerPrimes(self.interner, id, scope) == primes,
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
            .let => |l| self.captures(l.value, binder, spelling, primes, scope) or
                self.captures(l.body, binder, spelling, primes, scope),
            .letrec => |l| {
                for (l.bindings) |b| {
                    if (self.captures(b.value, binder, spelling, primes, scope)) return true;
                }
                return self.captures(l.body, binder, spelling, primes, scope);
            },
        };
    }

    fn writeScoped(self: Printer, g: Group, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope) Error!void {
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
            // `scope`'s innermost node is the binder, so its parent is where
            // the value is written.
            .let => |l| try self.writeBindings(
                "let",
                &.{.{ .name = l.name, .value = l.value }},
                l.body,
                w,
                indent,
                scope,
                scope.?.parent,
            ),
            .letrec => |l| try self.writeBindings("letrec", l.bindings, l.body, w, indent, scope, scope),
        }
    }

    /// Write `keyword`, each binding with its value in `value_scope`, `in`,
    /// and `body` on the next line.
    fn writeBindings(
        self: Printer,
        keyword: []const u8,
        bindings: []const Letrec.Binding,
        body: Term,
        w: *std.Io.Writer,
        indent: usize,
        scope: ?*print_scope.Scope,
        value_scope: ?*print_scope.Scope,
    ) Error!void {
        if (bindings.len == 1 and isFlat(bindings[0].value)) {
            try w.print("{s} ", .{keyword});
            try self.writeName(bindings[0].name, w, scope);
            try w.writeAll(" = ");
            try self.write(bindings[0].value, w, .top, indent, value_scope);
            try w.writeAll(" in");
        } else {
            try w.writeAll(keyword);
            for (bindings) |b| {
                try print_scope.newline(w, indent + 2);
                try self.writeName(b.name, w, scope);
                try w.writeAll(" =");
                try self.writeAfterArrow(b.value, w, indent + 2, value_scope);
            }
            try print_scope.newline(w, indent);
            try w.writeAll("in");
        }
        try print_scope.newline(w, indent);
        try self.write(body, w, .top, indent, scope);
    }

    fn writeName(self: Printer, id: SymbolId, w: *std.Io.Writer, scope: ?*print_scope.Scope) Error!void {
        try print_scope.writeName(self.interner, id, w, scope);
    }

    fn isFlat(t: Term) bool {
        return switch (t.kind) {
            .symbol, .literal => true,
            .lambda => |l| isFlat(l.body),
            .apply => |a| isFlat(a.function) and isFlat(a.argument),
            .case, .let, .letrec => false,
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

const expectPrints = test_support.expectPrints;

fn expectDefinitionPrints(pb: *const test_support.ProgramBuilder, expected: []const u8, name: SymbolId, body: Term) !void {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    const printer: Printer = .{ .interner = &pb.env.interner };
    try printer.definition(name, body, &w.writer);
    try std.testing.expectEqualStrings(expected, w.written());
}

test "a shadowing binder whose scope references the shadowed one is primed" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const outer = try pb.local("x");
    const inner = try pb.local("x");
    const term = try pb.lambda(&.{ outer, inner }, try pb.apply(pb.symbol(outer), &.{pb.symbol(inner)}));
    try expectPrints(&pb, "\\x -> \\x' -> x x'", term);
}

test "a shadowing binder whose scope does not reference the shadowed one is not primed" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const outer = try pb.local("x");
    const inner = try pb.local("x");
    const term = try pb.lambda(&.{ outer, inner }, pb.symbol(inner));
    try expectPrints(&pb, "\\x -> \\x -> x", term);
}

test "a local that hides a referenced global is primed" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const text = try pb.global("text");
    const local = try pb.local("text");
    const term = try pb.lambda(&.{local}, try pb.apply(pb.symbol(text), &.{pb.symbol(local)}));
    try expectPrints(&pb, "\\text' -> text text'", term);
}

test "each level of shadowing adds a prime" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const x0 = try pb.local("x");
    const x1 = try pb.local("x");
    const x2 = try pb.local("x");
    const body = try pb.apply(pb.symbol(x0), &.{ pb.symbol(x1), pb.symbol(x2) });
    try expectPrints(&pb, "\\x -> \\x' -> \\x'' -> x x' x''", try pb.lambda(&.{ x0, x1, x2 }, body));
}

test "an underscore binder is never primed" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const outer = try pb.local("_");
    const inner = try pb.local("_");
    try expectPrints(&pb, "\\_ -> \\_ -> _", try pb.lambda(&.{ outer, inner }, pb.symbol(outer)));
}

test "sibling binders of one spelling are told apart" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const cons = try pb.global("Cons");
    const xs = try pb.local("xs");
    const first = try pb.local("y");
    const second = try pb.local("y");
    const term = try pb.lambda(&.{xs}, try pb.case(pb.symbol(xs), &.{
        .{ .constructor = cons, .binders = &.{ first, second }, .body = try pb.apply(pb.symbol(first), &.{pb.symbol(second)}) },
    }));
    try expectPrints(&pb,
        \\\xs -> case xs of
        \\  Cons y' y -> y' y
    , term);
}

test "a letrec binding is in scope in its siblings' values" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const outer = try pb.local("a");
    const inner = try pb.local("a");
    const other = try pb.local("b");
    const term = try pb.lambda(&.{outer}, try pb.letrec(&.{
        .{ .name = inner, .value = pb.number(1) },
        .{ .name = other, .value = try pb.apply(pb.symbol(outer), &.{pb.symbol(inner)}) },
    }, pb.symbol(other)));
    try expectPrints(&pb,
        \\\a ->
        \\  letrec
        \\    a' = 1
        \\    b = a a'
        \\  in
        \\  b
    , term);
}

test "a let of one flat binding takes one line" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const f = try pb.global("f");
    const a = try pb.local("a");
    try expectDefinitionPrints(&pb,
        \\main =
        \\  let a = f 1 in
        \\  a
    , main, try pb.let(a, try pb.apply(pb.symbol(f), &.{pb.number(1)}), pb.symbol(a)));
}

test "a let binding whose value is not flat is laid out like a letrec's" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const a = try pb.local("a");
    const n = try pb.local("n");
    const value = try pb.lambda(&.{n}, try pb.case(pb.symbol(n), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
    }));
    try expectPrints(&pb,
        \\let
        \\  a = \n -> case n of
        \\    Nil -> 0
        \\in
        \\a
    , try pb.let(a, value, pb.symbol(a)));
}

test "a let operand is parenthesized across lines" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const a = try pb.local("a");
    try expectPrints(&pb,
        \\f (
        \\  let a = 1 in
        \\  a
        \\) 2
    , try pb.apply(pb.symbol(f), &.{ try pb.let(a, pb.number(1), pb.symbol(a)), pb.number(2) }));
}

test "a let binder is not in scope in its value" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const outer = try pb.local("x");
    const inner = try pb.local("x");
    const term = try pb.lambda(&.{outer}, try pb.let(
        inner,
        try pb.apply(pb.symbol(f), &.{pb.symbol(outer)}),
        pb.symbol(inner),
    ));
    try expectPrints(&pb,
        \\\x ->
        \\  let x = f x in
        \\  x
    , term);
}

test "a let binder whose body references the shadowed one is primed" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const outer = try pb.local("x");
    const inner = try pb.local("x");
    const term = try pb.lambda(&.{outer}, try pb.let(
        inner,
        try pb.apply(pb.symbol(f), &.{pb.symbol(outer)}),
        try pb.apply(pb.symbol(f), &.{ pb.symbol(outer), pb.symbol(inner) }),
    ));
    try expectPrints(&pb,
        \\\x ->
        \\  let x' = f x in
        \\  f x x'
    , term);
}

test "a negative number argument is parenthesized" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    try expectPrints(&pb, "f (-7) 1", try pb.apply(pb.symbol(f), &.{ pb.number(-7), pb.number(1) }));
}

test "a term without case or letrec prints on one line" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const x = try pb.local("x");
    const y = try pb.local("y");
    const term = try pb.lambda(&.{y}, try pb.apply(pb.symbol(f), &.{
        try pb.lambda(&.{x}, pb.symbol(x)),
        try pb.apply(pb.symbol(f), &.{pb.symbol(y)}),
    }));
    try expectPrints(&pb, "\\y -> f (\\x -> x) (f y)", term);
}

test "case alternatives each take a line, and a case alternative body hangs" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const xs = try pb.local("xs");
    const h = try pb.local("h");
    const rest = try pb.local("t");
    const inner = try pb.case(pb.symbol(rest), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(h) },
        .{ .constructor = cons, .binders = &.{ try pb.local("_"), try pb.local("_") }, .body = pb.number(0) },
    });
    const term = try pb.case(pb.symbol(xs), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
        .{ .constructor = cons, .binders = &.{ h, rest }, .body = inner },
    });
    try expectPrints(&pb,
        \\case xs of
        \\  Nil -> 0
        \\  Cons h t -> case t of
        \\    Nil -> h
        \\    Cons _ _ -> 0
    , term);
}

test "a letrec of one flat binding takes one line" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const f = try pb.global("f");
    const a = try pb.local("a");
    const term = try pb.letrec(&.{.{ .name = a, .value = try pb.apply(pb.symbol(f), &.{pb.number(1)}) }}, pb.symbol(a));
    try expectDefinitionPrints(&pb,
        \\main =
        \\  letrec a = f 1 in
        \\  a
    , main, term);
}

test "a letrec binding whose value is not flat is laid out like several" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const a = try pb.local("a");
    const n = try pb.local("n");
    const value = try pb.lambda(&.{n}, try pb.case(pb.symbol(n), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
    }));
    try expectPrints(&pb,
        \\letrec
        \\  a = \n -> case n of
        \\    Nil -> 0
        \\in
        \\a
    , try pb.letrec(&.{.{ .name = a, .value = value }}, pb.symbol(a)));
}

test "an operand that is not flat is parenthesized across lines" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const main = try pb.global("main");
    const f = try pb.global("f");
    const nil = try pb.global("Nil");
    const xs = try pb.local("xs");
    const argument = try pb.case(pb.symbol(xs), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
    });
    const term = try pb.lambda(&.{xs}, try pb.apply(pb.symbol(f), &.{ argument, pb.number(1) }));
    try expectDefinitionPrints(&pb,
        \\main = \xs -> f (
        \\  case xs of
        \\    Nil -> 0
        \\) 1
    , main, term);
}

test "a scrutinee that is not flat is parenthesized across lines" {
    var pb = try test_support.ProgramBuilder.init(std.testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const xs = try pb.local("xs");
    const inner = try pb.case(pb.symbol(xs), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.symbol(xs) },
    });
    const term = try pb.case(inner, &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
    });
    try expectPrints(&pb,
        \\case (
        \\  case xs of
        \\    Nil -> xs
        \\) of
        \\  Nil -> 0
    , term);
}
