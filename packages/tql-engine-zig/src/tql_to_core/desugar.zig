//! Surface CST to Core.

const std = @import("std");
const ts = @import("tree-sitter");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const primitives = @import("../primitives.zig");
const resolve = @import("resolve.zig");
const pcre2 = @import("../regex.zig");
const datatypes = core.datatypes;
const types = core.types;

pub const Error = error{DesugarFailed} || std.mem.Allocator.Error;

const Synthesized = core.Synthesized;

pub const Lowerer = struct {
    interner: *core.Interner,
    datatypes: *const datatypes.Registry,
    declarations: *const resolve.Declarations,
    language: *const ts.Language,
    sink: *diagnostic.Sink,
    builder: core.Builder,

    /// Global references made by the body currently being desugared, as
    /// declaration indices. Feeds the reference graph.
    references: std.ArrayList(u32) = .empty,

    pub fn init(
        builder: core.Builder,
        interner: *core.Interner,
        declared: *const datatypes.Registry,
        declarations: *const resolve.Declarations,
        language: *const ts.Language,
        sink: *diagnostic.Sink,
    ) Lowerer {
        return .{
            .interner = interner,
            .datatypes = declared,
            .declarations = declarations,
            .language = language,
            .sink = sink,
            .builder = builder,
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.references.deinit(self.builder.allocator);
    }

    /// A primitive or prelude name that sugar desugars to. Missing only when
    /// the prelude was not linked beneath this module.
    fn primitive(self: *Lowerer, name: []const u8, span: diagnostic.Span) Error!core.Term {
        const id = self.interner.lookup(name) orelse {
            try self.sink.report(.unresolved_name, span, "`{s}` is not defined", .{name});
            return error.DesugarFailed;
        };
        return self.builder.symbol(id, span);
    }

    fn constructorRef(
        self: *Lowerer,
        name: []const u8,
        span: diagnostic.Span,
    ) Error!core.Term {
        const id = self.interner.lookup(name) orelse {
            try self.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{name});
            return error.DesugarFailed;
        };
        if (datatypes.ownerOf(self.interner, id) == null) {
            try self.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{name});
            return error.DesugarFailed;
        }
        return self.builder.symbol(id, span);
    }

    fn caseOf(
        self: *Lowerer,
        c: cst.Case,
        scope: ?*const resolve.Scope,
        span: diagnostic.Span,
    ) Error!core.Term {
        const scrutinee = try self.expression(c.scrutinee, scope);

        if (c.alternatives.len == 0) {
            try self.sink.report(.type_mismatch, span, "a case has no alternatives", .{});
            return error.DesugarFailed;
        }

        const first = self.interner.lookup(c.alternatives[0].constructor) orelse {
            try self.sink.report(
                .unresolved_name,
                c.alternatives[0].span,
                "`{s}` is not a constructor",
                .{c.alternatives[0].constructor},
            );
            return error.DesugarFailed;
        };
        const owner = datatypes.ownerOf(self.interner, first) orelse {
            try self.sink.report(
                .unresolved_name,
                c.alternatives[0].span,
                "`{s}` is not a constructor",
                .{c.alternatives[0].constructor},
            );
            return error.DesugarFailed;
        };

        const declared = self.datatypes.get(owner);
        const slots = try self.builder.slice(?core.Case.Alternative, declared.constructors.len);
        @memset(slots, null);

        for (c.alternatives) |alternative| {
            const id = self.interner.lookup(alternative.constructor) orelse {
                try self.sink.report(
                    .unresolved_name,
                    alternative.span,
                    "`{s}` is not a constructor",
                    .{alternative.constructor},
                );
                return error.DesugarFailed;
            };
            const constructor = self.datatypes.constructorOf(self.interner, id) orelse {
                try self.sink.report(
                    .unresolved_name,
                    alternative.span,
                    "`{s}` is not a constructor",
                    .{alternative.constructor},
                );
                return error.DesugarFailed;
            };
            if (datatypes.ownerOf(self.interner, id).? != owner) {
                try self.sink.report(
                    .type_mismatch,
                    alternative.span,
                    "`{s}` is not a constructor of `{s}`",
                    .{ alternative.constructor, declared.name },
                );
                return error.DesugarFailed;
            }
            if (slots[constructor.tag] != null) {
                try self.sink.report(
                    .type_mismatch,
                    alternative.span,
                    "`{s}` is matched more than once",
                    .{alternative.constructor},
                );
                return error.DesugarFailed;
            }
            if (alternative.binders.len != constructor.fields.len) {
                try self.sink.report(
                    .type_mismatch,
                    alternative.span,
                    "`{s}` binds {d} field(s), given {d}",
                    .{ alternative.constructor, constructor.fields.len, alternative.binders.len },
                );
                return error.DesugarFailed;
            }

            const binders = try self.builder.slice(core.SymbolId, alternative.binders.len);
            const entries = try self.builder.slice(resolve.Scope.Entry, alternative.binders.len);
            for (alternative.binders, binders, entries) |binder, *slot, *entry| {
                slot.* = try self.interner.fresh(binder.name);
                entry.* = .{ .name = binder.name, .symbol = slot.* };
            }
            const inner: resolve.Scope = .{ .parent = scope, .names = entries };

            slots[constructor.tag] = .{
                .constructor = id,
                .binders = binders,
                .body = try self.expression(alternative.body, &inner),
            };
        }

        const alternatives = try self.builder.slice(core.Case.Alternative, slots.len);
        for (slots, alternatives, declared.constructors) |slot, *out, constructor| {
            out.* = slot orelse {
                try self.sink.report(
                    .type_mismatch,
                    span,
                    "`{s}` is not matched",
                    .{self.interner.spelling(constructor.symbol)},
                );
                return error.DesugarFailed;
            };
        }
        return try self.builder.case(scrutinee, alternatives, span);
    }

    fn recordReference(self: *Lowerer, symbol: core.SymbolId) !void {
        const index = self.declarations.indexOf(symbol) orelse return;
        for (self.references.items) |existing| {
            if (existing == index) return;
        }
        try self.references.append(self.builder.allocator, index);
    }

    /// The primitives spelled `name :k`, taking a kind token rather than a
    /// value. Each is one Core symbol, not an application.
    const kind_forms = [_]struct { spelling: []const u8, axis: ?core.PrimOp }{
        .{ .spelling = "is_kind", .axis = null },
        .{ .spelling = "children_of_kind", .axis = .children_of_kind },
        .{ .spelling = "descendants_of_kind", .axis = .descendants_of_kind },
    };

    /// Recognizes `is_kind :k` and the `_of_kind` axes, whose two surface
    /// tokens are one Core symbol. Returns null when this is an ordinary
    /// application. The inner error is the unknown-kind rejection.
    fn kindApplication(self: *Lowerer, a: cst.Apply) ?(Error!core.SymbolId) {
        const function = unwrap(a.function);
        const name = switch (function.kind) {
            .name => |n| n,
            else => return null,
        };
        const form = for (kind_forms) |candidate| {
            if (std.mem.eql(u8, name, candidate.spelling)) break candidate;
        } else return null;

        const argument = unwrap(a.argument);
        const kind = switch (argument.kind) {
            .kind_test => |k| k,
            else => return null,
        };
        // The rejection names the kind token, not the whole application.
        return self.synthesizeKindForm(form.spelling, form.axis, kind, argument.span);
    }

    fn synthesizeKindForm(
        self: *Lowerer,
        spelling: []const u8,
        axis: ?core.PrimOp,
        name: []const u8,
        span: diagnostic.Span,
    ) Error!core.SymbolId {
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
        const duped = try self.builder.dupe(name);
        const what: Synthesized = if (axis) |primop|
            .{ .kind_axis = .{ .name = duped, .id = id, .primop = primop } }
        else
            .{ .kind_test = .{ .name = duped, .id = id } };
        return try self.synthesize("{s}[{s}]", .{ spelling, name }, what);
    }

    /// Interns a synthesized symbol under its bracketed spelling and records
    /// what it was generated from.
    fn synthesize(
        self: *Lowerer,
        // IMPROVE: normalize differently in a non-stupid way
        comptime spelling_format: []const u8,
        spelling_args: anytype,
        what: Synthesized,
    ) Error!core.SymbolId {
        const spelling = try self.builder.print(spelling_format, spelling_args);
        return try self.interner.internOrGet(spelling, .{ .synthesized = what });
    }

    /// Parentheses are grouping only, so a form is recognized through them.
    fn unwrap(e: cst.Expression) cst.Expression {
        var current = e;
        while (current.kind == .parenthesized) current = current.kind.parenthesized.*;
        return current;
    }

    /// `f x_1 ... x_n = e` is nested unary lambdas. One desugaring, used by
    /// definitions, `let` bindings with parameters, and `\x y -> e`.
    pub fn parameterized(
        self: *Lowerer,
        parameters: []const cst.Parameter,
        body: cst.Expression,
        scope: ?*const resolve.Scope,
        span: diagnostic.Span,
    ) Error!core.Term {
        if (parameters.len == 0) return try self.expression(body, scope);

        const entries = try self.builder.slice(resolve.Scope.Entry, parameters.len);
        for (parameters, 0..) |p, i| {
            entries[i] = .{
                .name = p.name,
                .symbol = try self.interner.fresh(p.name),
            };
        }
        const inner: resolve.Scope = .{ .parent = scope, .names = entries };

        var term = try self.expression(body, &inner);
        var i = parameters.len;
        while (i > 0) {
            i -= 1;
            term = try self.builder.lambda(entries[i].symbol, term, span);
        }
        return term;
    }

    pub fn expression(self: *Lowerer, e: cst.Expression, scope: ?*const resolve.Scope) Error!core.Term {
        switch (e.kind) {
            // `.` is the singleton filter `\x -> [x]`, confusingly.
            // Unclear about the future of `.`
            .identity => return try self.builder.apply(
                try self.primitive("arr", e.span),
                try self.primitive("identity", e.span),
                e.span,
            ),

            // Literal payloads are duped: the CST they point into is freed
            // before the Core program is used.
            .number => |n| return self.builder.literal(.{ .number = n }, e.span),
            // A boolean is a nullary constructor, not a literal, so `case` on
            // one is uniform with `case` on any other declared type.
            .boolean => |b| return try self.primitive(if (b) "True" else "False", e.span),
            .string => |s| return self.builder.literal(
                .{ .string = try self.builder.dupe(s) },
                e.span,
            ),
            // Compiled here only to reject a malformed pattern as a compile
            // error rather than a runtime failure. Core keeps the pattern.
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
                return self.builder.literal(.{ .regex = try self.builder.dupe(r) }, e.span);
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
            // the `name :k` forms, which `.apply` handles.
            .kind_test => |name| {
                try self.sink.report(
                    .unresolved_name,
                    e.span,
                    "`:{s}` is only meaningful as the argument of `is_kind`, " ++
                        "`children_of_kind` or `descendants_of_kind`",
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
                        .{ .field = .{ .name = try self.builder.dupe(fa.field), .id = id } },
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
                if (self.kindApplication(a.*)) |symbol| {
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

            // The scalar conditional is `case` on `Bool`. Alternatives go in
            // tag order, so `False` precedes `True` and the alternative
            // bodies are the *opposite* order from how they are written.
            .@"if" => |i| {
                const alternatives = try self.builder.slice(core.Case.Alternative, 2);
                alternatives[0] = .{
                    .constructor = self.interner.lookup("False").?,
                    .binders = &.{},
                    .body = try self.expression(i.alternative, scope),
                };
                alternatives[1] = .{
                    .constructor = self.interner.lookup("True").?,
                    .binders = &.{},
                    .body = try self.expression(i.consequence, scope),
                };
                return try self.builder.case(
                    try self.expression(i.condition, scope),
                    alternatives,
                    e.span,
                );
            },

            .constructor => |name| return try self.constructorRef(name, e.span),

            .case => |c| return try self.caseOf(c.*, scope, e.span),

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

            .list => |elements| {
                var spine = try self.constructorRef("Nil", e.span);
                var i = elements.len;
                while (i > 0) {
                    i -= 1;
                    spine = try self.builder.applyMany(
                        try self.constructorRef("Cons", e.span),
                        &.{ try self.expression(elements[i], scope), spine },
                        e.span,
                    );
                }
                return spine;
            },

            .record => |r| return try self.record(r, e.span, scope),
        }
    }

    fn binary(self: *Lowerer, b: cst.Binary, span: diagnostic.Span, scope: ?*const resolve.Scope) Error!core.Term {
        const left = try self.expression(b.left, scope);
        const right = try self.expression(b.right, scope);

        const combinator: ?[]const u8 = switch (b.operator) {
            .pipe => "kleisli",
            .stream_union => "alt",
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
        const scalar: core.Scalar = switch (b.operator) {
            .divide => .divide,
            .multiply => .multiply,
            .modulo => .modulo,
            .add => .add,
            .subtract => .subtract,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .lte => .lte,
            .gt => .gt,
            .gte => .gte,
            .match => .match,
            .not_match => .not_match,
            .pipe, .stream_union, .@"and", .@"or" => unreachable,
        };
        const operator = try self.synthesize(
            "op[{s}]",
            .{scalar.spelling()},
            .{ .operator = scalar },
        );
        return try self.builder.applyMany(
            self.builder.symbol(operator, span),
            &.{ left, right },
            span,
        );
    }

    /// `{l = e, ...}` is the synthesized `record[l,...]` applied to each
    /// field's expression. Labels are normalized so `{a=1,b=2}` and `{b=2,a=1}`
    /// produce one symbol, and the arguments follow the normalized order.
    fn record(self: *Lowerer, r: cst.Record, span: diagnostic.Span, scope: ?*const resolve.Scope) Error!core.Term {
        const order = try self.builder.slice(u32, r.fields.len);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sortUnstable(u32, order, r.fields, struct {
            fn lt(fields: []const cst.RecordField, a: u32, b: u32) bool {
                return std.mem.order(u8, fields[a].name, fields[b].name) == .lt;
            }
        }.lt);

        const labels = try self.builder.slice([]const u8, r.fields.len);
        const arguments = try self.builder.slice(core.Term, r.fields.len);
        for (order, 0..) |source_index, i| {
            labels[i] = r.fields[source_index].name;
            arguments[i] = try self.expression(r.fields[source_index].value, scope);
        }

        const owned = try self.builder.slice([]const u8, labels.len);
        for (labels, 0..) |label, i| owned[i] = try self.builder.dupe(label);
        const symbol = try self.synthesize(
            "record[{s}]",
            .{try self.builder.join(",", labels)},
            .{ .record = owned },
        );
        return try self.builder.applyMany(
            self.builder.symbol(symbol, span),
            arguments,
            span,
        );
    }

    const Group = struct {
        bindings: []const core.Letrec.Binding,
        scope: resolve.Scope,
    };

    /// A surface `let` group is a Core `letrec` even with one binding and no
    /// recursion. Bindings are mutually scoped, so every name is in scope in
    /// every value.
    fn bindingGroup(
        self: *Lowerer,
        bindings: []const cst.Binding,
        scope: ?*const resolve.Scope,
        span: diagnostic.Span,
    ) Error!Group {
        const entries = try self.builder.slice(resolve.Scope.Entry, bindings.len);
        for (bindings, 0..) |b, i| {
            entries[i] = .{
                .name = b.name,
                .symbol = try self.interner.fresh(b.name),
            };
        }
        const inner: resolve.Scope = .{ .parent = scope, .names = entries };

        const resolved = try self.builder.slice(core.Letrec.Binding, bindings.len);
        for (bindings, 0..) |b, i| {
            resolved[i] = .{
                .name = entries[i].symbol,
                .value = try self.parameterized(b.parameters, b.value, &inner, span),
            };
        }

        return .{ .bindings = resolved, .scope = inner };
    }

    fn doBlock(
        self: *Lowerer,
        statements: []const cst.Statement,
        result: cst.Expression,
        scope: ?*const resolve.Scope,
        span: diagnostic.Span,
    ) Error!core.Term {
        if (statements.len == 0) return try self.expression(result, scope);

        switch (statements[0]) {
            .bind => |b| {
                const value = try self.expression(b.value, scope);
                const symbol = try self.interner.fresh(b.name);
                const entries = try self.builder.slice(resolve.Scope.Entry, 1);
                entries[0] = .{ .name = b.name, .symbol = symbol };
                const inner: resolve.Scope = .{ .parent = scope, .names = entries };
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

/// One desugared source file: definitions and the references between them.
///
/// `edges` are module-local indices into `definitions`.
pub const Module = struct {
    definitions: []const core.Definition,
    edges: []const []const u32,
};
