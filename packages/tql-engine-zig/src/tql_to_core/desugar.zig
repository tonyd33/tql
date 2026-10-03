//! Surface CST to Core.

const std = @import("std");
const ts = @import("tree-sitter");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const primitives = @import("../primitives.zig");
const resolve = @import("resolve.zig");
const ModuleScope = @import("scope.zig").ModuleScope;
const match = @import("match.zig");
const pcre2 = @import("../regex.zig");
const datatypes = core.datatypes;
const types = core.types;

pub const Error = error{DesugarFailed} || std.mem.Allocator.Error;

const Synthesized = core.Synthesized;

pub const Lowerer = struct {
    interner: *core.Interner,
    datatypes: *const datatypes.Registry,
    scope: *const ModuleScope,
    /// The linked index of every definition in this module and those before.
    linked: *const std.AutoHashMapUnmanaged(core.SymbolId, u32),
    language: *const ts.Language,
    sink: *diagnostic.Sink,
    builder: core.Builder,

    /// Global references made by the body currently being desugared, as
    /// linked indices. Feeds the reference graph.
    references: std.ArrayList(u32) = .empty,

    pub fn init(
        builder: core.Builder,
        interner: *core.Interner,
        scope: *const ModuleScope,
        linked: *const std.AutoHashMapUnmanaged(core.SymbolId, u32),
        language: *const ts.Language,
        sink: *diagnostic.Sink,
    ) Lowerer {
        return .{
            .interner = interner,
            .datatypes = scope.datatypes,
            .scope = scope,
            .linked = linked,
            .language = language,
            .sink = sink,
            .builder = builder,
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.references.deinit(self.builder.allocator);
    }

    /// A primitive or prelude name that sugar desugars to, resolved in the
    /// prelude whatever this module declares. Missing only when the prelude
    /// was not linked beneath this module.
    fn primitive(self: *Lowerer, name: []const u8, span: diagnostic.Span) Error!core.Term {
        const id = self.interner.lookup(.prelude, name) orelse {
            try self.sink.report(.unresolved_name, span, "`{s}` is not defined", .{name});
            return error.DesugarFailed;
        };
        return self.builder.symbol(id, span);
    }

    /// The global `name` names in this module's scope, or null. Reports an
    /// ambiguous name.
    pub fn resolveGlobal(self: *Lowerer, name: []const u8, span: diagnostic.Span) Error!?core.SymbolId {
        return switch (self.scope.value(name)) {
            .found => |id| id,
            .missing => null,
            .ambiguous => |modules| {
                try self.scope.reportAmbiguous(self.sink, span, name, modules);
                return error.DesugarFailed;
            },
        };
    }

    fn constructorRef(
        self: *Lowerer,
        name: []const u8,
        span: diagnostic.Span,
    ) Error!core.Term {
        const id = try self.resolveGlobal(name, span) orelse {
            try self.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{name});
            return error.DesugarFailed;
        };
        if (datatypes.ownerOf(self.interner, id) == null) {
            try self.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{name});
            return error.DesugarFailed;
        }
        return self.builder.symbol(id, span);
    }

    fn recordReference(self: *Lowerer, symbol: core.SymbolId) !void {
        const index = self.linked.get(symbol) orelse return;
        for (self.references.items) |existing| {
            if (existing == index) return;
        }
        try self.references.append(self.builder.allocator, index);
    }

    /// Resolve a `:k` literal against the target grammar. These literals are
    /// the only source of kind values.
    fn kindLiteral(self: *Lowerer, name: []const u8, span: diagnostic.Span) Error!core.Term {
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
        if (self.language.nodeKindIsSupertype(id)) {
            try self.sink.report(
                .supertype_kind,
                span,
                "`{s}` is a supertype, so no node has this kind{f}",
                .{ name, SubtypeList{ .language = self.language, .supertype = id } },
            );
            return error.DesugarFailed;
        }
        return self.builder.literal(
            .{ .kind = .{ .name = try self.builder.dupe(name), .id = id } },
            span,
        );
    }

    /// Formats as `; use one of its subtypes: ...`, or nothing when the
    /// grammar does not record them.
    const SubtypeList = struct {
        language: *const ts.Language,
        supertype: u16,

        pub fn format(self: SubtypeList, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const subtypes = self.language.subtypesForSupertype(self.supertype);
            if (subtypes.len == 0) return;
            try w.writeAll("; use one of its subtypes:");
            for (subtypes, 0..) |subtype, i| {
                const separator = if (i == 0) " " else ", ";
                try w.print("{s}`{s}`", .{ separator, self.language.nodeKindForId(subtype) orelse "?" });
            }
        }
    };

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
                if (try self.resolveGlobal(name, e.span)) |global| {
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

            .kind_test => |name| return try self.kindLiteral(name, e.span),

            // A leading `#f` is the bare `field[f]`.
            .navigation => |n| {
                const id = self.language.fieldIdForName(n.field);
                if (id == 0) {
                    try self.sink.report(
                        .unknown_field,
                        e.span,
                        "`{s}` is not a field in this grammar",
                        .{n.field},
                    );
                    return error.DesugarFailed;
                }
                const field = self.builder.symbol(
                    try self.synthesize(
                        "field[{s}]",
                        .{n.field},
                        .{ .field = .{ .name = try self.builder.dupe(n.field), .id = id } },
                    ),
                    e.span,
                );
                const subject = n.node orelse return field;
                return try self.builder.apply(field, try self.expression(subject, scope), e.span);
            },

            // `_.l` is the bare `select[l]`, and `_.l.m` a lambda reading
            // through both.
            .projection => |p| {
                if (p.record == null) return try self.select(p.label, e.span);
                if (!isSection(e)) return try self.projections(e, null, scope);
                const parameter = try self.interner.fresh("_");
                return try self.builder.lambda(
                    parameter,
                    try self.projections(e, self.builder.symbol(parameter, e.span), scope),
                    e.span,
                );
            },

            .apply => |a| return try self.builder.apply(
                try self.expression(a.function, scope),
                try self.expression(a.argument, scope),
                e.span,
            ),

            .binary => |b| return try self.binaryTerms(
                b.operator,
                try self.expression(b.left, scope),
                try self.expression(b.right, scope),
                e.span,
            ),

            .section => |s| return try self.section(s.*, e.span, scope),

            // The scalar conditional is `case` on `Bool`. Alternatives go in
            // tag order, so `False` precedes `True` and the alternative
            // bodies are the *opposite* order from how they are written.
            .@"if" => |i| {
                const alternatives = try self.builder.slice(core.Case.Alternative, 2);
                alternatives[0] = .{
                    .constructor = self.interner.lookup(.prelude, "False").?,
                    .binders = &.{},
                    .body = try self.expression(i.alternative, scope),
                };
                alternatives[1] = .{
                    .constructor = self.interner.lookup(.prelude, "True").?,
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

            .case => |c| return try match.caseOf(self, c.*, scope, e.span),

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
                var spine = try self.primitive("Nil", e.span);
                var i = elements.len;
                while (i > 0) {
                    i -= 1;
                    // An inner cell spans its head element.
                    const cell = if (i == 0) e.span else elements[i].span;
                    spine = try self.builder.applyMany(
                        try self.primitive("Cons", cell),
                        &.{ try self.expression(elements[i], scope), spine },
                        cell,
                    );
                }
                return spine;
            },

            .record => |r| return try self.record(r, e.span, scope),
        }
    }

    fn select(self: *Lowerer, label: []const u8, span: diagnostic.Span) Error!core.Term {
        return self.builder.symbol(
            try self.synthesize("select[{s}]", .{label}, .{ .select = try self.builder.dupe(label) }),
            span,
        );
    }

    /// Whether `e` is a projection chain starting at `_`.
    fn isSection(e: cst.Expression) bool {
        var current = e;
        while (current.kind == .projection) {
            current = current.kind.projection.record orelse return true;
        }
        return false;
    }

    /// The chain of projections `e`, read from `hole` in place of `_`.
    fn projections(
        self: *Lowerer,
        e: cst.Expression,
        hole: ?core.Term,
        scope: ?*const resolve.Scope,
    ) Error!core.Term {
        const p = e.kind.projection;
        const subject = if (p.record) |r| switch (r.kind) {
            .projection => try self.projections(r, hole, scope),
            else => try self.expression(r, scope),
        } else hole.?;
        return try self.builder.apply(try self.select(p.label, e.span), subject, e.span);
    }

    /// `(op)` is `\x y -> x op y`, `(e op)` is `\y -> e op y` and `(op e)` is
    /// `\x -> x op e`. A compound `e` is bound outside the lambda and
    /// evaluated at most once.
    fn section(self: *Lowerer, s: cst.Section, span: diagnostic.Span, scope: ?*const resolve.Scope) Error!core.Term {
        if (s.operator == .function and s.left == null and s.right == null) {
            return try self.expression(s.operator.function, scope);
        }

        var binding: ?core.Letrec.Binding = null;
        const left = try self.sectionOperand(s.left, &binding, span, scope);
        const right = try self.sectionOperand(s.right, &binding, span, scope);

        const left_term = left orelse self.builder.symbol(try self.interner.fresh("x"), span);
        const right_term = right orelse self.builder.symbol(try self.interner.fresh("y"), span);
        var result = switch (s.operator) {
            .binary => |operator| try self.binaryTerms(operator, left_term, right_term, span),
            .dollar => try self.builder.apply(left_term, right_term, span),
            .function => |f| try self.builder.applyMany(
                try self.expression(f, scope),
                &.{ left_term, right_term },
                span,
            ),
        };
        if (right == null) result = try self.builder.lambda(right_term.kind.symbol, result, span);
        if (left == null) result = try self.builder.lambda(left_term.kind.symbol, result, span);

        const operand = binding orelse return result;
        return try self.builder.letrec(try self.builder.dupeSlice(core.Letrec.Binding, &.{operand}), result, span);
    }

    /// A written operand as an atom, setting `binding` when it is compound.
    fn sectionOperand(
        self: *Lowerer,
        operand: ?cst.Expression,
        binding: *?core.Letrec.Binding,
        span: diagnostic.Span,
        scope: ?*const resolve.Scope,
    ) Error!?core.Term {
        const written = operand orelse return null;
        const term = try self.expression(written, scope);
        switch (term.kind) {
            .symbol, .literal => return term,
            else => {},
        }
        const name = try self.interner.fresh("e");
        binding.* = .{ .name = name, .value = term };
        return self.builder.symbol(name, span);
    }

    fn binaryTerms(
        self: *Lowerer,
        op: cst.BinaryOperator,
        left: core.Term,
        right: core.Term,
        span: diagnostic.Span,
    ) Error!core.Term {
        // Scalar operators are ordinary functions on scalars: `op[=] n 0`,
        // never lifted over filters.
        const scalar: core.Scalar = switch (op) {
            .pipe => return try self.combinator("kleisli", left, right, span),
            .stream_union => return try self.combinator("alt", left, right, span),
            .compose => return try self.combinator("compose", left, right, span),
            .then => return try self.builder.bind(try self.interner.fresh("_"), left, right, span),
            .cons => return try self.builder.applyMany(
                try self.primitive("Cons", span),
                &.{ left, right },
                span,
            ),
            .@"and" => return try self.combinator("and", left, right, span),
            .@"or" => return try self.combinator("or", left, right, span),
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

    fn combinator(self: *Lowerer, name: []const u8, left: core.Term, right: core.Term, span: diagnostic.Span) Error!core.Term {
        return try self.builder.applyMany(
            try self.primitive(name, span),
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
            .expression => |e| {
                return try self.builder.bind(
                    try self.interner.fresh("_"),
                    try self.expression(e, scope),
                    try self.doBlock(statements[1..], result, scope, span),
                    e.span,
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
