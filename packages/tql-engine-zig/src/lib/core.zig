//! Core terms.
//!
//! ```
//! expr ::= symbol
//!        | literal
//!        | \x -> expr
//!        | expr_1 expr_2
//!        | case expr of { C x_1 .. x_n -> expr; ...; _ -> expr }
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
pub const classes = @import("core/classes.zig");
pub const print_scope = @import("core/print_scope.zig");
pub const free = @import("core/free.zig");
pub const lint = @import("core/lint.zig");
pub const components = @import("core/components.zig");
pub const test_support = @import("core/test_support.zig");
const program = @import("core/program.zig");

/// A linked program, and what every stage after desugaring reads.
pub const Program = program.Program;
pub const printProgram = program.printProgram;

pub const Synthesized = details.Synthesized;
pub const PrimOp = details.PrimOp;
pub const Pseudo = details.Pseudo;
pub const Operation = details.Operation;
pub const Scalar = details.Scalar;
pub const Comparison = details.Comparison;

pub const SymbolId = symbols.SymbolId;
pub const ModuleId = symbols.ModuleId;
pub const Known = symbols.Known;
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

    /// The body under the first `n` lambdas.
    ///
    /// Preconditions: `t` starts with at least `n` lambdas.
    pub fn underLambdas(t: Term, n: usize) Term {
        var body = t;
        for (0..n) |_| body = body.kind.lambda.body;
        return body;
    }

    /// Write the parameters of the first `parameters.len` lambdas into
    /// `parameters`, and return the body under them.
    ///
    /// Preconditions: `t` starts with at least `parameters.len` lambdas.
    pub fn peel(t: Term, parameters: []SymbolId) Term {
        var body = t;
        for (parameters) |*parameter| {
            parameter.* = body.kind.lambda.parameter;
            body = body.kind.lambda.body;
        }
        return body;
    }

    /// The function at the head of an application spine, or the term itself.
    pub fn head(t: Term) Term {
        var result = t;
        while (result.kind == .apply) result = result.kind.apply.function;
        return result;
    }

    /// How many arguments the head of an application spine is applied to.
    pub fn spineLength(t: Term) usize {
        var count: usize = 0;
        var current = t;
        while (current.kind == .apply) : (current = current.kind.apply.function) count += 1;
        return count;
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

/// Evaluates the scrutinee to WHNF, then takes the alternative naming its
/// constructor, or `default` when none does.
pub const Case = struct {
    scrutinee: Term,
    alternatives: []const Alternative,
    default: ?Term = null,

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

    /// `\p_1 .. p_n -> body`, at `body`'s span.
    pub fn abstract(self: Builder, parameters: []const SymbolId, body: Term) !Term {
        var result = body;
        var i = parameters.len;
        while (i > 0) {
            i -= 1;
            result = try self.lambda(parameters[i], result, body.span);
        }
        return result;
    }

    pub fn case(
        self: Builder,
        scrutinee: Term,
        alternatives: []const Case.Alternative,
        span: diagnostic.Span,
    ) !Term {
        return try self.caseWithDefault(scrutinee, alternatives, null, span);
    }

    pub fn caseWithDefault(
        self: Builder,
        scrutinee: Term,
        alternatives: []const Case.Alternative,
        default: ?Term,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Case);
        node.* = .{ .scrutinee = scrutinee, .alternatives = alternatives, .default = default };
        return .{ .kind = .{ .case = node }, .span = span };
    }

    /// `case scrutinee of { _ -> body }`: evaluate `scrutinee`, then `body`.
    pub fn force(self: Builder, scrutinee: Term, body: Term, span: diagnostic.Span) !Term {
        return try self.caseWithDefault(scrutinee, &.{}, body, span);
    }

    /// `case condition of { False -> otherwise; True -> matched }`.
    ///
    /// Alternatives go in tag order, so `False` precedes `True` and the
    /// alternative bodies are the opposite order from how an `if` writes them.
    pub fn choose(
        self: Builder,
        declared: *const datatypes.Registry,
        condition: Term,
        otherwise: Term,
        matched: Term,
        span: diagnostic.Span,
    ) !Term {
        const alternatives = try self.dupeSlice(Case.Alternative, &.{
            .{ .constructor = declared.boolConstructor(false).symbol, .binders = &.{}, .body = otherwise },
            .{ .constructor = declared.boolConstructor(true).symbol, .binders = &.{}, .body = matched },
        });
        return try self.case(condition, alternatives, span);
    }

    /// `case order of { LT -> bodies[0]; EQ -> bodies[1]; GT -> bodies[2] }`.
    pub fn chooseOrder(
        self: Builder,
        declared: *const datatypes.Registry,
        order: Term,
        bodies: [3]Term,
        span: diagnostic.Span,
    ) !Term {
        const alternatives = try self.slice(Case.Alternative, 3);
        for (alternatives, [_]std.math.Order{ .lt, .eq, .gt }, bodies) |*alternative, o, body| {
            alternative.* = .{ .constructor = declared.orderingConstructor(o).symbol, .binders = &.{}, .body = body };
        }
        return try self.case(order, alternatives, span);
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
        parameters: Parameters,

        pub fn len(g: Group) usize {
            return switch (g) {
                .lambda, .let => 1,
                .alternative => |a| a.binders.len,
                .letrec => |l| l.bindings.len,
                .parameters => |p| p.count,
            };
        }

        pub fn binder(g: Group, i: usize) SymbolId {
            return switch (g) {
                .lambda => |l| l.parameter,
                .alternative => |a| a.binders[i],
                .let => |l| l.name,
                .letrec => |l| l.bindings[i].name,
                .parameters => |p| p.lambda(i).parameter,
            };
        }
    };

    /// A join point's first `count` lambdas, written as parameters before
    /// `=`.
    const Parameters = struct {
        value: Term,
        count: usize,

        fn lambda(p: Parameters, i: usize) *const Lambda {
            return p.value.underLambdas(i).kind.lambda;
        }

        fn body(p: Parameters) Term {
            return p.value.underLambdas(p.count);
        }
    };

    fn joinArity(self: Printer, id: SymbolId) ?u32 {
        return self.interner.details(id).joinArity();
    }

    /// Whether `t` is a call of a join point with all its arguments.
    fn isJump(self: Printer, t: Term) bool {
        const head = t.head();
        if (head.kind != .symbol) return false;
        const arity = self.joinArity(head.kind.symbol) orelse return false;
        return arity == t.spineLength();
    }

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
            .symbol => |id| {
                if (self.isJump(t)) try w.writeAll("jump ");
                try self.writeName(id, w, scope);
            },
            .literal => |value| try writeLiteral(value, w),
            .lambda => |l| try self.enter(.{ .lambda = l }, w, indent, scope),
            .apply => |a| {
                if (self.isJump(t)) try w.writeAll("jump ");
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
                if (c.default) |default| {
                    try print_scope.newline(w, indent + 2);
                    try w.writeAll("_ ->");
                    try self.writeAfterArrow(default, w, indent + 2, scope);
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
            .parameters => |p| self.captures(p.body(), binder, spelling, primes, scope),
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
                if (c.default) |default| return self.captures(default, binder, spelling, primes, scope);
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
                false,
                &.{.{ .name = l.name, .value = l.value }},
                l.body,
                w,
                indent,
                scope,
                scope.?.parent,
            ),
            .letrec => |l| try self.writeBindings(true, l.bindings, l.body, w, indent, scope, scope),
            .parameters => |p| {
                for (0..p.count) |i| {
                    try w.writeByte(' ');
                    try self.writeName(p.lambda(i).parameter, w, scope);
                }
                try w.writeAll(" =");
                try self.writeAfterArrow(p.body(), w, indent, scope);
            },
        }
    }

    /// Write `name`, a join point's parameters, `=`, and its value.
    fn writeBinding(self: Printer, b: Letrec.Binding, w: *std.Io.Writer, indent: usize, scope: ?*print_scope.Scope, value_scope: ?*print_scope.Scope) Error!void {
        try self.writeName(b.name, w, scope);
        const arity = self.joinArity(b.name) orelse 0;
        if (arity > 0) return try self.enter(.{ .parameters = .{ .value = b.value, .count = arity } }, w, indent, value_scope);
        try w.writeAll(" =");
        try self.writeAfterArrow(b.value, w, indent, value_scope);
    }

    /// Write the keyword, each binding with its value in `value_scope`, `in`,
    /// and `body` on the next line.
    fn writeBindings(
        self: Printer,
        recursive: bool,
        bindings: []const Letrec.Binding,
        body: Term,
        w: *std.Io.Writer,
        indent: usize,
        scope: ?*print_scope.Scope,
        value_scope: ?*print_scope.Scope,
    ) Error!void {
        const keyword = if (self.joinArity(bindings[0].name) != null)
            (if (recursive) "joinrec" else "join")
        else
            (if (recursive) "letrec" else "let");
        if (bindings.len == 1 and isFlat(bindings[0].value)) {
            try w.print("{s} ", .{keyword});
            try self.writeBinding(bindings[0], w, indent, scope, value_scope);
            try w.writeAll(" in");
        } else {
            try w.writeAll(keyword);
            for (bindings) |b| {
                try print_scope.newline(w, indent + 2);
                try self.writeBinding(b, w, indent + 2, scope, value_scope);
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
