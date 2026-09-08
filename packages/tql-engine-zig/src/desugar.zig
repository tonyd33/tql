//! Surface CST to Core.

const std = @import("std");
const ts = @import("tree-sitter");
const core = @import("core.zig");
const cst = @import("cst.zig");
const diagnostic = @import("diagnostic.zig");
const grammar = @import("grammar.zig");
const resolve = @import("resolve.zig");
const pcre2 = @import("regex.zig");
const symbols = @import("symbols.zig");

const Scope = resolve.Scope;
const Span = diagnostic.Span;
const SymbolId = symbols.SymbolId;
const Term = core.Term;

pub const Error = error{DesugarFailed} || std.mem.Allocator.Error;

/// What a synthesized symbol was generated from. The information must be
/// injected at this step as its unrecoverable later.
pub const Synthesis = union(enum) {
    /// `is_kind[k]`, carrying the resolved grammar kind ID.
    kind_test: struct { name: []const u8, id: u16 },
    /// `field[l]`, carrying the resolved grammar field ID.
    field: struct { name: []const u8, id: u16 },
    /// `op[+]` and friends.
    operator: []const u8,
    /// `record_filter[l,...]`, labels in normalized order. The scheme is n-ary
    /// in the field count, so inference builds it from these rather than
    /// reading one off a table.
    record_filter: []const []const u8,
};

pub const SynthesisTable = symbols.SymbolTable(Synthesis);

pub const Desugarer = struct {
    arena: std.mem.Allocator,
    interner: *symbols.Interner,
    synthesis: *SynthesisTable,
    declarations: *const resolve.Declarations,
    language: *const ts.Language,
    sink: *diagnostic.Sink,
    builder: core.Builder,

    /// Global references made by the body currently being desugared, as
    /// declaration indices. Feeds the reference graph.
    references: std.ArrayList(u32) = .empty,

    pub fn init(
        arena: std.mem.Allocator,
        interner: *symbols.Interner,
        synthesis: *SynthesisTable,
        declarations: *const resolve.Declarations,
        language: *const ts.Language,
        sink: *diagnostic.Sink,
    ) Desugarer {
        return .{
            .arena = arena,
            .interner = interner,
            .synthesis = synthesis,
            .declarations = declarations,
            .language = language,
            .sink = sink,
            .builder = .{ .allocator = arena },
        };
    }

    pub fn deinit(self: *Desugarer) void {
        self.references.deinit(self.arena);
    }

    /// A primitive by name. Every one is interned before desugaring runs, so a
    /// miss is a bug in the table rather than a user error.
    fn primitive(self: *Desugarer, name: []const u8, span: Span) !Term {
        const id = self.interner.lookup(name).?;
        return self.builder.symbol(id, span);
    }

    fn recordReference(self: *Desugarer, symbol: SymbolId) !void {
        const index = self.declarations.indexOf(symbol) orelse return;
        for (self.references.items) |existing| {
            if (existing == index) return;
        }
        try self.references.append(self.arena, index);
    }

    /// Recognizes `is_kind :k`, whose two surface tokens are one Core symbol.
    /// Returns null when this is an ordinary application. The inner error is
    /// the unknown-kind rejection.
    fn kindTestApplication(self: *Desugarer, a: cst.Apply) ?(Error!SymbolId) {
        const function = unwrap(a.function);
        const name = switch (function.kind) {
            .name => |n| n,
            else => return null,
        };
        if (!std.mem.eql(u8, name, "is_kind")) return null;

        const argument = unwrap(a.argument);
        const kind = switch (argument.kind) {
            .kind_test => |k| k,
            else => return null,
        };
        // The rejection names the kind token, not the whole application.
        return self.synthesizeKindTest(kind, argument.span);
    }

    fn synthesizeKindTest(self: *Desugarer, name: []const u8, span: Span) Error!SymbolId {
        const id = self.language.idForNodeKind(name, true);
        if (id == 0) {
            try self.sink.report(
                .unknown_kind,
                span,
                "`{s}` is not a node kind in this grammar",
                .{name},
            );
            return error.DesugarFailed;
        }
        return try self.synthesize(
            "is_kind[{s}]",
            .{name},
            .{ .kind_test = .{ .name = try self.arena.dupe(u8, name), .id = id } },
        );
    }

    /// Interns a synthesized symbol under its bracketed spelling and records
    /// what it was generated from.
    fn synthesize(
        self: *Desugarer,
        // IMPROVE: normalize differently in a non-stupid way
        comptime spelling_format: []const u8,
        spelling_args: anytype,
        what: Synthesis,
    ) Error!SymbolId {
        const spelling = try std.fmt.allocPrint(self.arena, spelling_format, spelling_args);
        const id = try self.interner.internOrGet(spelling);
        try self.synthesis.put(id, what);
        return id;
    }

    /// Parentheses are grouping only, so a form is recognized through them.
    fn unwrap(e: cst.Expression) cst.Expression {
        var current = e;
        while (current.kind == .parenthesized) current = current.kind.parenthesized.*;
        return current;
    }

    /// `f x_1 ... x_n = e` is nested unary lambdas. One desugaring, used by
    /// definitions, `let` bindings with parameters, and `\x y -> e`.
    fn parameterized(
        self: *Desugarer,
        parameters: []const cst.Parameter,
        body: cst.Expression,
        scope: ?*const Scope,
        span: Span,
    ) Error!Term {
        if (parameters.len == 0) return try self.expression(body, scope);

        const entries = try self.arena.alloc(Scope.Entry, parameters.len);
        for (parameters, 0..) |p, i| {
            entries[i] = .{
                .name = p.name,
                .symbol = try self.interner.fresh(p.name),
            };
        }
        const inner: Scope = .{ .parent = scope, .names = entries };

        var term = try self.expression(body, &inner);
        var i = parameters.len;
        while (i > 0) {
            i -= 1;
            term = try self.builder.lambda(entries[i].symbol, term, span);
        }
        return term;
    }

    pub fn expression(self: *Desugarer, e: cst.Expression, scope: ?*const Scope) Error!Term {
        switch (e.kind) {
            .identity => return try self.primitive("identity", e.span),

            // Literal payloads are duped: the CST they point into is freed
            // before the Core program is used.
            .number => |n| return self.builder.literal(.{ .number = n }, e.span),
            .boolean => |b| return self.builder.literal(.{ .boolean = b }, e.span),
            .string => |s| return self.builder.literal(
                .{ .string = try self.arena.dupe(u8, s) },
                e.span,
            ),
            // The pattern is compiled here, so a malformed one is a compile
            // error rather than a runtime failure.
            .regex => |r| {
                var compiled = pcre2.Regex.compile(r) catch {
                    try self.sink.report(
                        .invalid_regex,
                        e.span,
                        "`{s}` is not a valid regular expression",
                        .{r},
                    );
                    return error.DesugarFailed;
                };
                compiled.deinit();
                return self.builder.literal(
                    .{ .regex = try self.arena.dupe(u8, r) },
                    e.span,
                );
            },

            // Parentheses are grouping only; the CST keeps them, Core does not.
            .parenthesized => |inner| return try self.expression(inner.*, scope),

            .name => |name| {
                if (scope) |s| {
                    if (s.lookup(name)) |local| return self.builder.symbol(local, e.span);
                }
                if (self.interner.lookup(name)) |global| {
                    try self.recordReference(global);
                    return self.builder.symbol(global, e.span);
                }
                try self.sink.report(
                    .unresolved_name,
                    e.span,
                    "`{s}` is not defined",
                    .{name},
                );
                return error.DesugarFailed;
            },

            // A kind is not a first-class value: it reaches Core only through
            // the `is_kind :k` form, which `.apply` handles.
            .kind_test => |name| {
                try self.sink.report(
                    .unresolved_name,
                    e.span,
                    "`:{s}` is only meaningful as the argument of `is_kind`",
                    .{name},
                );
                return error.DesugarFailed;
            },

            // A leading `.l` is the bare `field[l]`.
            .field_access => |fa| {
                const id = self.language.fieldIdForName(fa.field);
                if (id == 0) {
                    try self.sink.report(
                        .unknown_field,
                        e.span,
                        "`{s}` is not a field in this grammar",
                        .{fa.field},
                    );
                    return error.DesugarFailed;
                }
                const field = self.builder.symbol(
                    try self.synthesize(
                        "field[{s}]",
                        .{fa.field},
                        .{ .field = .{ .name = try self.arena.dupe(u8, fa.field), .id = id } },
                    ),
                    e.span,
                );
                const subject = fa.record orelse return field;
                return try self.builder.apply(
                    field,
                    try self.expression(subject, scope),
                    e.span,
                );
            },

            // `is_kind :k` is one synthesized symbol, not an application of a
            // the `is_kind` primitive to a kind value: the kind resolves against the
            // target grammar at desugaring time, and there is no first-class
            // kind value for a general application to take.
            .apply => |a| {
                if (self.kindTestApplication(a.*)) |symbol| {
                    return self.builder.symbol(try symbol, e.span);
                }
                return try self.builder.apply(
                    try self.expression(a.function, scope),
                    try self.expression(a.argument, scope),
                    e.span,
                );
            },

            .binary => |b| return try self.binary(b.*, e.span, scope),

            .not => |n| return try self.builder.apply(
                try self.primitive("not", e.span),
                try self.expression(n.operand, scope),
                e.span,
            ),

            // The scalar conditional is a Core term form, not an application.
            .@"if" => |i| return try self.builder.conditional(
                try self.expression(i.condition, scope),
                try self.expression(i.consequence, scope),
                try self.expression(i.alternative, scope),
                e.span,
            ),

            .lambda => |l| return try self.parameterized(l.parameters, l.body, scope, e.span),

            .let => |l| {
                const group = try self.bindingGroup(l.bindings, scope, e.span);
                return try self.builder.letrec(
                    group.bindings,
                    try self.expression(l.body, &group.scope),
                    e.span,
                );
            },

            .do => |d| return try self.doBlock(d.statements, d.result, scope, e.span),

            // `[p]` is `collect p`; `[]` is `collect empty`, which is why it
            // yields one empty list rather than no output.
            .list => |maybe| {
                const inner = if (maybe) |p|
                    try self.expression(p.*, scope)
                else
                    try self.primitive("empty", e.span);
                return try self.builder.apply(
                    try self.primitive("collect", e.span),
                    inner,
                    e.span,
                );
            },

            .record => |r| return try self.record(r, e.span, scope),
        }
    }

    fn binary(self: *Desugarer, b: cst.Binary, span: Span, scope: ?*const Scope) Error!Term {
        const left = try self.expression(b.left, scope);
        const right = try self.expression(b.right, scope);

        const combinator: ?[]const u8 = switch (b.operator) {
            .pipe => "compose",
            .stream_union => "union",
            .@"and" => "and",
            .@"or" => "or",
            else => null,
        };

        if (combinator) |name| {
            return try self.builder.applyMany(
                try self.primitive(name, span),
                &.{ left, right },
                span,
            );
        }

        // Scalar operators are ordinary functions on scalars: `op[=] n 0`,
        // never lifted over filters.
        const spelling = b.operator.spelling();
        const operator = try self.synthesize(
            "op[{s}]",
            .{spelling},
            .{ .operator = try self.arena.dupe(u8, spelling) },
        );
        return try self.builder.applyMany(
            self.builder.symbol(operator, span),
            &.{ left, right },
            span,
        );
    }

    /// `{l = p, ...}` is the synthesized `record_filter[l,...]` applied to each
    /// field's expression. Labels are normalized so `{a=1,b=2}` and `{b=2,a=1}`
    /// produce one symbol, and the arguments follow the normalized order.
    fn record(self: *Desugarer, r: cst.Record, span: Span, scope: ?*const Scope) Error!Term {
        const order = try self.arena.alloc(u32, r.fields.len);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sortUnstable(u32, order, r.fields, struct {
            fn lt(fields: []const cst.RecordField, a: u32, b: u32) bool {
                return std.mem.order(u8, fields[a].name, fields[b].name) == .lt;
            }
        }.lt);

        const labels = try self.arena.alloc([]const u8, r.fields.len);
        const arguments = try self.arena.alloc(Term, r.fields.len);
        for (order, 0..) |source_index, i| {
            labels[i] = r.fields[source_index].name;
            arguments[i] = try self.expression(r.fields[source_index].value, scope);
        }

        const owned = try self.arena.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| owned[i] = try self.arena.dupe(u8, label);
        const symbol = try self.synthesize(
            "record_filter[{s}]",
            .{try std.mem.join(self.arena, ",", labels)},
            .{ .record_filter = owned },
        );
        return try self.builder.applyMany(
            self.builder.symbol(symbol, span),
            arguments,
            span,
        );
    }

    const Group = struct {
        bindings: []const core.Letrec.Binding,
        scope: Scope,
    };

    /// A surface `let` group is a Core `letrec` even with one binding and no
    /// recursion. Bindings are mutually scoped, so every name is in scope in
    /// every value.
    fn bindingGroup(
        self: *Desugarer,
        bindings: []const cst.Binding,
        scope: ?*const Scope,
        span: Span,
    ) Error!Group {
        const entries = try self.arena.alloc(Scope.Entry, bindings.len);
        for (bindings, 0..) |b, i| {
            entries[i] = .{
                .name = b.name,
                .symbol = try self.interner.fresh(b.name),
            };
        }
        const inner: Scope = .{ .parent = scope, .names = entries };

        const resolved = try self.arena.alloc(core.Letrec.Binding, bindings.len);
        for (bindings, 0..) |b, i| {
            resolved[i] = .{
                .name = entries[i].symbol,
                .value = try self.parameterized(b.parameters, b.value, &inner, span),
            };
        }

        return .{ .bindings = resolved, .scope = inner };
    }

    /// Statements nest to the right, one Core binder per statement — the
    /// opposite direction from a pipe chain.
    fn doBlock(
        self: *Desugarer,
        statements: []const cst.Statement,
        result: cst.Expression,
        scope: ?*const Scope,
        span: Span,
    ) Error!Term {
        if (statements.len == 0) return try self.expression(result, scope);

        switch (statements[0]) {
            .bind => |b| {
                const value = try self.expression(b.value, scope);
                const symbol = try self.interner.fresh(b.name);
                const entries = try self.arena.alloc(Scope.Entry, 1);
                entries[0] = .{ .name = b.name, .symbol = symbol };
                const inner: Scope = .{ .parent = scope, .names = entries };
                return try self.builder.bind(
                    symbol,
                    value,
                    try self.doBlock(statements[1..], result, &inner, span),
                    b.span,
                );
            },
            .let => |l| {
                const group = try self.bindingGroup(l.bindings, scope, l.span);
                return try self.builder.letrec(
                    group.bindings,
                    try self.doBlock(statements[1..], result, &group.scope, span),
                    l.span,
                );
            },
        }
    }
};

/// One compiled source file: definitions and the references between them.
///
/// `edges` are module-local indices into `definitions`.
///
/// Terms live in the arena the desugarer was given, which the module does not
/// own; one arena backs every module in a link.
pub const Module = struct {
    definitions: []const core.Definition,
    edges: []const []const u32,
};

/// Desugars one source file into a `Module`: collect heads, resolve bodies.
///
/// Terms are allocated into `arena`, which the caller owns and which must
/// outlive the module.
pub fn module(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    interner: *symbols.Interner,
    synthesis: *SynthesisTable,
    source: cst.SourceFile,
    g: *const grammar.Grammar,
    sink: *diagnostic.Sink,
) !Module {
    var declarations = try resolve.collect(allocator, interner, source, sink);
    defer declarations.deinit();

    const definitions = try arena.alloc(core.Definition, declarations.items.items.len);
    const edges = try arena.alloc([]const u32, declarations.items.items.len);
    @memset(edges, &.{});

    // IMPROVE: desugar the entire module at once with a single desugar pass?
    var failed = false;
    for (declarations.items.items, 0..) |d, i| {
        var desugarer = Desugarer.init(
            arena,
            interner,
            synthesis,
            &declarations,
            g.language,
            sink,
        );
        defer desugarer.deinit();

        const body = desugarer.parameterized(
            d.definition.parameters,
            d.definition.body,
            null,
            d.definition.span,
        ) catch |err| switch (err) {
            error.DesugarFailed => {
                failed = true;
                continue;
            },
            else => |e| return e,
        };

        definitions[i] = .{ .symbol = d.symbol, .body = body };
        edges[i] = try arena.dupe(u32, desugarer.references.items);
    }

    if (failed or sink.hasErrors()) return error.DesugarFailed;

    return .{ .definitions = definitions, .edges = edges };
}
