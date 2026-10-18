//! Algorithm W over Core, with a mutable substitution. Inference elaborates:
//! each term is rebuilt with dictionary passing made explicit.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const evidence = @import("evidence.zig");
const classes = core.classes;
const types = core.types;
const unify = @import("unify.zig");

const Allocator = std.mem.Allocator;
const Substitution = @import("substitution.zig").Substitution;

pub const Failure = struct {
    category: diagnostic.Category,
    span: diagnostic.Span,
    detail: Detail,

    pub const Detail = union(enum) {
        mismatch: unify.Mismatch,
        /// A constraint no instance satisfies.
        violation: types.TypeClassConstraint,
        over_application: types.Type,
        not_a_function: types.Type,
        view_not_function: types.Type,
        unbound: core.SymbolId,
        too_many_variables: usize,
        ambiguous: types.TypeClassConstraint,
        ambiguous_output: types.Type,
        /// An instance whose head lacks a superclass of its class.
        superclass: struct {
            instance: classes.InstanceId,
            needed: types.TypeClassConstraint,
        },
    };
};

pub const Error = Allocator.Error;

/// What a symbol's type is, by where the symbol came from.
const Binding = union(enum) {
    scheme: types.Scheme,
    monomorphic: types.Type,
    /// A member of the recursive group being inferred, before the group is
    /// generalized.
    member: types.Type,
};

/// Lexical scope
const Scope = struct {
    entries: std.ArrayList(Entry),
    gpa: Allocator,

    const Entry = struct {
        symbol: core.SymbolId,
        binding: Binding,
    };

    fn init(gpa: Allocator) Scope {
        return .{ .entries = .empty, .gpa = gpa };
    }

    fn deinit(self: *Scope) void {
        self.entries.deinit(self.gpa);
    }

    pub fn push(self: *Scope, symbol: core.SymbolId, binding: Binding) !void {
        try self.entries.append(self.gpa, .{ .symbol = symbol, .binding = binding });
    }

    fn mark(self: *const Scope) usize {
        return self.entries.items.len;
    }

    fn truncate(self: *Scope, to: usize) void {
        self.entries.shrinkRetainingCapacity(to);
    }

    /// Innermost binding wins.
    fn lookup(self: *const Scope, symbol: core.SymbolId) ?Binding {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].symbol == symbol) return self.entries.items[i].binding;
        }
        return null;
    }
};

pub const Inference = struct {
    gpa: Allocator,
    subst: *Substitution,
    scope: Scope,
    /// Schemes generalized so far, by symbol. An earlier SCC's result.
    inferred: core.SymbolTable(types.Scheme),
    /// Declared types and classes, written signatures, and every symbol.
    /// Evidence variables and dictionary parameters are interned here.
    env: *core.env.Env,
    /// Every insoluble wanted, equalities included, in the order found,
    /// without those about a poisoned type.
    failures: std.ArrayList(Failure) = .empty,
    /// Definitions, top-level or local, whose type was poisoned when they
    /// were generalized. A use of one has a poisoned type, since its scheme
    /// quantified the poison away.
    failed: std.AutoHashMapUnmanaged(core.SymbolId, void) = .empty,
    /// Builds elaborated terms in the environment's arena.
    builder: core.Builder,
    evidence: evidence.Table,
    /// The generalized body being inferred.
    frame: u32 = evidence.top,
    /// Each top-level definition's elaborated body, where it differs from
    /// the written one.
    elaborated: core.SymbolTable(core.Term),
    /// Each instance's dictionary, as `finish` builds it.
    instances: std.ArrayList(evidence.Instance) = .empty,
    /// The evidence `main` is applied to.
    entry_evidence: []const core.Term = &.{},
    /// `main`, while a program is checked.
    entry: ?core.SymbolId = null,

    pub fn init(
        gpa: Allocator,
        subst: *Substitution,
        target: *core.env.Env,
    ) Error!Inference {
        return .{
            .gpa = gpa,
            .subst = subst,
            .env = target,
            .scope = Scope.init(gpa),
            .inferred = core.SymbolTable(types.Scheme).init(gpa),
            .builder = .{ .allocator = target.allocator() },
            .evidence = try evidence.Table.init(gpa),
            .elaborated = core.SymbolTable(core.Term).init(gpa),
        };
    }

    pub fn deinit(self: *Inference) void {
        self.instances.deinit(self.gpa);
        self.failed.deinit(self.gpa);
        self.failures.deinit(self.gpa);
        self.elaborated.deinit();
        self.evidence.deinit();
        self.inferred.deinit();
        self.scope.deinit();
    }

    /// A term's type, and the term with each use of a constrained name
    /// applied to evidence variables and each generalized `let` abstracted
    /// over its dictionaries. A subterm with nothing to elaborate is shared.
    pub const Elaborated = struct {
        type: types.Type,
        term: core.Term,
    };

    pub fn elaborate(self: *Inference, t: core.Term) Error!Elaborated {
        return switch (t.kind) {
            .symbol => |id| try self.variable(id, t.span),
            .literal => |lit| .{ .type = self.literal(lit), .term = t },
            .lambda => |lam| try self.lambda(lam.*, t),
            .apply => |app| try self.application(app.*, t),
            .case => |c| try self.caseOf(c.*, t),
            .let => |l| try self.let(l.*, t),
            .letrec => |l| try self.letrec(l.*, t),
        };
    }

    const Instantiated = struct {
        type: types.Type,
        /// One evidence variable per dictionary constraint, in the scheme's
        /// order.
        evidence: []const core.Term,
    };

    /// Instantiating a scheme also raises its constraints, on the fresh
    /// metavariables its bound variables became, as wanteds of the current
    /// frame.
    fn instantiate(self: *Inference, scheme: types.Scheme, span: diagnostic.Span) Error!Instantiated {
        const inst = try self.subst.instantiate(scheme);
        var variables: std.ArrayList(core.Term) = .empty;
        for (scheme.constraints) |c| {
            const symbol = try self.raise(self.frame, c.class, try self.subst.instantiateWith(c.type, inst.metas), span);
            if (symbol) |s| try variables.append(self.builder.allocator, self.builder.symbol(s, span));
        }
        return .{ .type = inst.type, .evidence = variables.items };
    }

    /// Raises `class t` as a wanted of frame `at`. Returns its fresh
    /// evidence variable, or null when the machine handles `class`.
    fn raise(self: *Inference, at: u32, class: classes.ClassId, t: types.Type, origin: diagnostic.Span) Error!?core.SymbolId {
        const symbol = if (self.env.classes.evidenceOf(class) == .dictionary) try self.env.interner.fresh("evidence") else null;
        try self.evidence.want(at, .{ .class = class, .type = t, .evidence = symbol, .origin = origin });
        return symbol;
    }

    /// A use of `id` at a fresh instance of `scheme`.
    fn occurrence(self: *Inference, id: core.SymbolId, scheme: types.Scheme, span: diagnostic.Span) Error!Elaborated {
        const inst = try self.instantiate(scheme, span);
        return .{
            .type = inst.type,
            .term = try self.builder.applyMany(self.builder.symbol(id, span), inst.evidence, span),
        };
    }

    /// Binds each constraint of `context` as a given of `frame`. Returns the
    /// dictionary parameters, one per constraint with dictionary evidence,
    /// in order.
    fn parameters(self: *Inference, frame: u32, context: []const types.TypeClassConstraint) Error![]const core.SymbolId {
        const bound = try self.builder.slice(core.SymbolId, self.env.classes.dictionaryCount(context));
        var i: usize = 0;
        for (context) |c| {
            const parameter = if (self.env.classes.evidenceOf(c.class) == .dictionary) blk: {
                bound[i] = try self.env.interner.fresh("d");
                i += 1;
                break :blk bound[i - 1];
            } else null;
            try self.evidence.give(frame, .{ .class = c.class, .type = c.type, .evidence = parameter });
        }
        return bound;
    }

    /// (T-Lit)       ty(c) = tau
    ///               ----------------
    ///               Gamma |- c : tau
    fn literal(self: *Inference, lit: core.Literal) types.Type {
        _ = self;
        return switch (lit) {
            .number => types.int_type,
            .string => types.string_type,
            .regex => types.regex_type,
            .kind => types.kind_type,
        };
    }

    /// (T-Var)       Gamma(x) = sigma       instantiate sigma = tau
    ///               ------------------------------------------
    ///               Gamma |- x : tau
    ///
    /// `Gamma(x)` has five sources, in scope order:
    /// 1. a written signature, wherever its definition's SCC is
    /// 2. a lexical binder
    /// 3. this SCC's placeholder
    /// 4. an earlier SCC's scheme
    /// 5. the environment's scheme for a primitive, a synthesized symbol, a
    ///    constructor or a method
    ///
    /// A definition that failed, or a name that is not defined, has no type
    /// to give, so a use of one has a poisoned type.
    fn variable(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!Elaborated {
        if (self.env.annotationOf(id)) |declared| return try self.occurrence(id, declared.scheme, span);
        if (!self.failed.contains(id)) {
            if (self.scope.lookup(id)) |binding| return switch (binding) {
                // Monomorphic: used at one type, not instantiated.
                .monomorphic => |t| .{ .type = t, .term = self.builder.symbol(id, span) },
                .member => |t| .{ .type = t, .term = self.builder.symbol(id, span) },
                .scheme => |s| try self.occurrence(id, s, span),
            };
            if (self.inferred.get(id)) |s| return try self.occurrence(id, s, span);
            if (self.env.schemeOf(id)) |s| return try self.occurrence(id, s, span);
            try self.report(.unresolved_name, span, .{ .unbound = id });
        }
        return .{ .type = try self.poisoned(), .term = self.builder.symbol(id, span) };
    }

    /// A fresh poisoned metavariable.
    fn poisoned(self: *Inference) Error!types.Type {
        const t = try self.subst.fresh(.type);
        self.subst.poison(t);
        return t;
    }

    /// Binds `name` to its generalization in scope, recording it as failed
    /// when its type was poisoned.
    fn bindGeneralized(self: *Inference, name: core.SymbolId, g: Generalized) Error!void {
        if (g.poisoned) try self.failed.put(self.gpa, name, {});
        try self.scope.push(name, .{ .scheme = g.scheme });
    }

    /// (T-Lam)       Gamma, x : alpha |- e : tau
    ///               ------------------------------
    ///               Gamma |- \x -> e : alpha -> tau
    fn lambda(self: *Inference, lam: core.Lambda, t: core.Term) Error!Elaborated {
        const parameter = try self.subst.fresh(.type);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(lam.parameter, .{ .monomorphic = parameter });

        const body = try self.elaborate(lam.body);
        return .{
            .type = try types.func(self.subst.arena, parameter, body.type),
            .term = if (core.same(body.term, lam.body)) t else try self.builder.lambda(lam.parameter, body.term, t.span),
        };
    }

    /// (T-App)       Gamma |- e_1 : tau_1 -> tau_2
    ///               Gamma |- e_2 : tau_1
    ///               -------------------------------------------------------
    ///               Gamma |- e_1 e_2 : tau_2
    fn application(self: *Inference, app: core.Apply, t: core.Term) Error!Elaborated {
        const function = try self.elaborate(app.function);
        const operand = try self.elaborate(app.argument);
        const callee = function.type;
        const argument = operand.type;

        const parameter = try self.subst.fresh(.type);
        const result = try self.subst.fresh(.type);
        const arrow = try types.func(self.subst.arena, parameter, result);
        switch (try unify.unify(self.subst, callee, arrow)) {
            .unified => switch (try unify.unify(self.subst, parameter, argument)) {
                .unified => {},
                .mismatch => |m| try self.reportAbout(.type_mismatch, app.argument.span, .{ .mismatch = m }, &.{ arrow, argument }),
            },
            .mismatch => if (app.view) try self.reportAbout(
                .type_mismatch,
                app.function.span,
                .{ .view_not_function = self.subst.resolve(callee) },
                &.{ callee, arrow, argument },
            ) else if (app.function.kind != .apply) try self.reportAbout(
                .type_mismatch,
                app.function.span,
                .{ .not_a_function = self.subst.resolve(callee) },
                &.{ callee, arrow, argument },
            ) else try self.reportAbout(
                // This isn't and can never be a function. Therefore we're
                // over applying.
                .over_application,
                app.argument.span,
                .{ .over_application = self.subst.resolve(callee) },
                &.{ callee, arrow, argument },
            ),
        }

        const unchanged = core.same(function.term, app.function) and core.same(operand.term, app.argument);
        return .{
            .type = result,
            .term = if (unchanged) t else blk: {
                var rebuilt = app;
                rebuilt.function = function.term;
                rebuilt.argument = operand.term;
                break :blk try self.builder.application(rebuilt, t.span);
            },
        };
    }

    /// (T-Case)      Gamma |- e : T tau_1 .. tau_m
    ///               C_i : sigma_i_1 -> .. -> sigma_i_k -> T a_1 .. a_m
    ///               Gamma, b : T tau_1 .. tau_m, xs_i : [a := tau] sigma_i |- e_i : tau
    ///               Gamma, b : T tau_1 .. tau_m |- e_0 : tau
    ///               ------------------------------------------------------------
    ///               Gamma |- case e of b { C_i xs_i -> e_i; _ -> e_0 } : tau
    fn caseOf(self: *Inference, c: core.Case, t: core.Term) Error!Elaborated {
        const elaborated_scrutinee = try self.elaborate(c.scrutinee);
        const scrutinee = elaborated_scrutinee.type;

        // The alternatives name their constructors statically, so the datatype
        // is known without resolving the scrutinee. Unifying against it at
        // fresh arguments is what lets `case xs of ...` fix `xs`'s type rather
        // than requiring it to be fixed already. A `case` with only a default
        // leaves the scrutinee's type free.
        var arguments: []types.Type = &.{};
        if (c.alternatives.len > 0) {
            const owner = core.datatypes.ownerOf(&self.env.interner, c.alternatives[0].constructor).?;
            const declared = self.env.datatypes.get(owner);
            arguments = try self.subst.arena.alloc(types.Type, declared.parameters.len);
            for (arguments, declared.parameters) |*argument, kind| argument.* = try self.subst.fresh(kind);
            const scrutinee_type = try types.constructed(self.subst.arena, owner, declared.name, arguments);
            try self.expect(scrutinee, scrutinee_type, c.scrutinee.span);
        }

        const outer = self.scope.mark();
        defer self.scope.truncate(outer);
        if (c.binder) |binder| try self.scope.push(binder, .{ .monomorphic = scrutinee });

        var first: ?Branch = null;
        var alternatives: core.Rebuilt(core.Case.Alternative) = .{ .original = c.alternatives };
        for (c.alternatives, 0..) |alternative, i| {
            const mark = self.scope.mark();
            defer self.scope.truncate(mark);

            const constructor = self.env.datatypes.constructorOf(&self.env.interner, alternative.constructor).?;
            for (alternative.binders, constructor.fields) |binder, field| {
                const at = try self.subst.instantiateWith(field, arguments);
                try self.scope.push(binder, .{ .monomorphic = at });
            }

            const elaborated_body = try self.elaborate(alternative.body);
            try alternatives.set(self.builder, i, .{
                .constructor = alternative.constructor,
                .binders = alternative.binders,
                .body = elaborated_body.term,
            }, !core.same(elaborated_body.term, alternative.body));
            try self.joinBranch(&first, elaborated_body.type, alternative.body.span);
        }

        var default = c.default;
        if (c.default) |body| {
            const elaborated_default = try self.elaborate(body);
            default = elaborated_default.term;
            try self.joinBranch(&first, elaborated_default.type, body.span);
        }

        const unchanged = alternatives.copy == null and
            core.same(elaborated_scrutinee.term, c.scrutinee) and
            core.sameOptional(default, c.default);
        return .{
            .type = first.?.type,
            .term = if (unchanged) t else try self.builder.caseOf(.{
                .scrutinee = elaborated_scrutinee.term,
                .binder = c.binder,
                .alternatives = alternatives.copy orelse c.alternatives,
                .default = default,
            }, t.span),
        };
    }

    const Branch = struct { type: types.Type, span: diagnostic.Span };

    /// Unify a `case` branch's type with the first branch's, or record it as
    /// the first.
    fn joinBranch(self: *Inference, first: *?Branch, body: types.Type, span: diagnostic.Span) Error!void {
        if (first.*) |f| {
            // Alternatives are checked in constructor order. Of two that
            // disagree, blame the one later in the source.
            if (span.start_byte >= f.span.start_byte) {
                try self.expect(body, f.type, span);
            } else {
                try self.expect(f.type, body, f.span);
            }
        } else {
            first.* = .{ .type = body, .span = span };
        }
    }

    /// (T-Let)       Gamma |- e_1 : tau_1      sigma = Gen(Gamma, tau_1)
    ///               Gamma, x : sigma |- e_2 : tau_2
    ///               ------------------------------------------------
    ///               Gamma |- let x = e_1 in e_2 : tau_2
    fn let(self: *Inference, l: core.Let, t: core.Term) Error!Elaborated {
        if (self.env.interner.details(l.name).joinArity()) |arity| return try self.joinPoint(l, t, arity);
        const frame = try self.evidence.frame(self.frame);
        const elaborated_value = blk: {
            const enclosing = self.frame;
            defer self.frame = enclosing;
            self.frame = frame;
            break :blk try self.elaborate(l.value);
        };

        var generalized: [1]Generalized = undefined;
        const quantified = try self.generalizeGroup(&.{elaborated_value.type}, &.{l.value.span}, &.{frame}, &generalized);
        const bound = try self.parameters(frame, generalized[0].context);
        try self.solve(frame, quantified);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.bindGeneralized(l.name, generalized[0]);
        const body = try self.elaborate(l.body);

        const new_value = try self.builder.abstract(bound, try self.evidence.wrap(self.builder, frame, elaborated_value.term));
        const unchanged = core.same(new_value, l.value) and core.same(body.term, l.body);
        return .{
            .type = body.type,
            .term = if (unchanged) t else try self.builder.let(l.name, new_value, body.term, t.span),
        };
    }

    /// (T-LetJoin)   Gamma |- \x_1 .. x_n -> u : tau_1 -> .. -> tau_n -> tau
    ///               Gamma, j : tau_1 -> .. -> tau_n -> tau |- e : tau
    ///               ------------------------------------------------
    ///               Gamma |- let j = \x_1 .. x_n -> u in e : tau      (j is join(n))
    ///
    /// `j` is monomorphic. Its value is elaborated in the enclosing frame.
    fn joinPoint(self: *Inference, l: core.Let, t: core.Term, arity: u32) Error!Elaborated {
        const value = try self.elaborate(l.value);
        var result = value.type;
        for (0..arity) |_| result = self.subst.expand(result).function.to;

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(l.name, .{ .monomorphic = value.type });
        const body = try self.elaborate(l.body);
        try self.expect(body.type, result, l.body.span);

        const unchanged = core.same(value.term, l.value) and core.same(body.term, l.body);
        return .{
            .type = body.type,
            .term = if (unchanged) t else try self.builder.let(l.name, value.term, body.term, t.span),
        };
    }

    /// (T-LetRec)    Gamma, x_i : alpha_i |- e_i : tau_i       (each i)
    ///               alpha_i unifies with tau_i
    ///               sigma_i = Gen(Gamma, tau_i)                (each i)
    ///               Gamma, x_i : sigma_i |- body : result
    ///               ------------------------------------------------------
    ///               Gamma |- letrec {x_i = e_i} in body : result
    fn letrec(self: *Inference, l: core.Letrec, t: core.Term) Error!Elaborated {
        const mark = self.scope.mark();
        defer self.scope.truncate(mark);

        var group = try Group.init(self.gpa, l.bindings.len);
        defer group.deinit(self.gpa);
        for (l.bindings, group.spans()) |b, *span| span.* = b.value.span;
        const quantified = try self.inferGroup(l.bindings, &group);

        for (group.generalized(), group.frames(), group.bound()) |g, frame, *slot| slot.* = try self.parameters(frame, g.context);
        for (group.frames()) |f| try self.solve(f, quantified);

        var bindings: core.Rebuilt(core.Letrec.Binding) = .{ .original = l.bindings };
        for (l.bindings, group.generalized(), 0..) |b, g, i| {
            const abstracted = try self.close(&group, i, l.bindings);
            try bindings.set(self.builder, i, .{ .name = b.name, .value = abstracted }, !core.same(abstracted, b.value));
            try self.bindGeneralized(b.name, g);
        }
        const body = try self.elaborate(l.body);
        const unchanged = bindings.copy == null and core.same(body.term, l.body);
        return .{
            .type = body.type,
            .term = if (unchanged) t else try self.builder.letrec(bindings.copy orelse l.bindings, body.term, t.span),
        };
    }

    /// Each member of a group being inferred, by field.
    const Group = struct {
        members: std.MultiArrayList(Member) = .empty,

        const Member = struct {
            /// Where generalization reports.
            span: diagnostic.Span,
            generalized: Generalized,
            /// The frame its body was elaborated in.
            frame: u32,
            /// Its elaborated body.
            value: core.Term,
            /// Its dictionary parameters.
            bound: []const core.SymbolId,
        };

        fn init(gpa: Allocator, len: usize) Allocator.Error!Group {
            var group: Group = .{};
            try group.members.resize(gpa, len);
            return group;
        }

        fn deinit(self: *Group, gpa: Allocator) void {
            self.members.deinit(gpa);
        }

        fn spans(self: *Group) []diagnostic.Span {
            return self.members.items(.span);
        }

        fn generalized(self: *Group) []Generalized {
            return self.members.items(.generalized);
        }

        fn frames(self: *Group) []u32 {
            return self.members.items(.frame);
        }

        fn values(self: *Group) []core.Term {
            return self.members.items(.value);
        }

        fn bound(self: *Group) [][]const core.SymbolId {
            return self.members.items(.bound);
        }
    };

    /// Member `i` of `group`: its body, with each use of a member of
    /// `recursive` applied to its dictionaries, under the evidence its frame
    /// solved, abstracted over its dictionary parameters.
    fn close(self: *Inference, group: *Group, i: usize, recursive: []const core.Letrec.Binding) Error!core.Term {
        const dictionaries = group.bound()[i];
        const translated = try self.recursiveUses(recursive, dictionaries, group.values()[i]);
        return try self.builder.abstract(dictionaries, try self.evidence.wrap(self.builder, group.frames()[i], translated));
    }

    /// Infer a group of mutually recursive bindings and generalize them
    /// together, writing each one's generalization, frame and elaborated
    /// body to `group`. Generalization reports against `group`'s spans.
    ///
    /// Returns the metavariables the group quantifies.
    fn inferGroup(
        self: *Inference,
        bindings: []const core.Letrec.Binding,
        group: *Group,
    ) Error![]const types.Meta {
        const spans = group.spans();
        const frames = group.frames();
        const placeholders = try self.gpa.alloc(types.Type, bindings.len);
        defer self.gpa.free(placeholders);
        for (bindings, placeholders) |b, *p| p.* = switch (self.env.interner.details(b.name)) {
            .matcher => |m| try self.matcherShape(m.arity),
            else => try self.subst.fresh(.type),
        };

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        for (bindings, placeholders) |b, p| {
            try self.scope.push(b.name, .{ .member = p });
        }

        // Each inferred body must unify with its placeholder.
        const enclosing = self.frame;
        defer self.frame = enclosing;
        for (bindings, placeholders, frames, group.values()) |b, p, *frame, *value| {
            frame.* = try self.evidence.frame(enclosing);
            self.frame = frame.*;
            const inferred = try self.elaborate(b.value);
            try self.expect(inferred.type, p, b.value.span);
            value.* = inferred.term;
        }

        // `main` is checked at `Filter Node tau` before it generalizes, so it
        // quantifies over nothing that type determines.
        for (bindings, placeholders, spans) |b, p, span| {
            if (b.name == self.entry) _ = try self.mainOutput(p, span);
        }

        // Generalize against the environment *outside* the group, so the
        // placeholders being dropped is what lets them be quantified.
        self.scope.truncate(mark);
        return try self.generalizeGroup(placeholders, spans, frames, group.generalized());
    }

    /// A matcher's type of `arity` holes, each variable fresh.
    fn matcherShape(self: *Inference, arity: u32) Error!types.Type {
        const holes = try self.subst.arena.alloc(types.Type, arity);
        for (holes) |*hole| hole.* = try self.subst.fresh(.type);
        return try types.matcher(self.subst.arena, try self.subst.fresh(.type), holes, try self.subst.fresh(.type));
    }

    /// One member's generalization.
    pub const Generalized = struct {
        scheme: types.Scheme,
        /// The metavariables the scheme's bound variables were, in order.
        metas: []const types.Meta,
        /// The group's context, over those metavariables.
        context: []const types.TypeClassConstraint,
        /// Whether its type was poisoned before it was generalized.
        poisoned: bool,
    };

    /// `Gen(Gamma, tau_i)` for every member of a group checked together,
    /// whose wanteds are those of `frames`.
    ///
    /// Each member quantifies the metavariables free in its own type but not
    /// in the environment.
    ///
    /// The group has one context: each wanted is reduced through instances
    /// to its residuals, and the context is those mentioning a quantified
    /// metavariable, without duplicates or those a superclass of another
    /// implies. Every member takes the whole context, quantifying the
    /// metavariables it mentions. The wanteds are solved under it by
    /// `solve`, once the caller has bound it as givens.
    ///
    /// Reports a member whose type does not mention a metavariable its
    /// context quantifies. See Ambiguity in type_check.zig.
    ///
    /// Returns the metavariables the group quantifies.
    ///
    /// Preconditions:
    /// - `spans.len == group.len`
    /// - `out.len == group.len`
    fn generalizeGroup(
        self: *Inference,
        group: []const types.Type,
        spans: []const diagnostic.Span,
        frames: []const u32,
        out: []Generalized,
    ) Error![]const types.Meta {
        var env: std.ArrayList(types.Meta) = .empty;
        defer env.deinit(self.gpa);
        for (self.scope.entries.items) |e| switch (e.binding) {
            .monomorphic, .member => |m| try self.subst.freeMetas(m, &env),
            // A scheme's own quantified variables are bound, not free; only
            // what its constraints still mention could be.
            .scheme => {},
        };

        // Every member's quantified metavariables, laid end to end. Member
        // `i`'s are `quantified[bounds[i]..bounds[i + 1]]`.
        var quantified: std.ArrayList(types.Meta) = .empty;
        defer quantified.deinit(self.gpa);
        const bounds = try self.gpa.alloc(usize, group.len + 1);
        defer self.gpa.free(bounds);

        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        for (group, 0..) |t, i| {
            bounds[i] = quantified.items.len;
            free.clearRetainingCapacity();
            try self.subst.freeMetas(t, &free);
            for (free.items) |id| {
                for (env.items) |bound| {
                    if (id == bound) break;
                } else try quantified.append(self.gpa, id);
            }
        }
        bounds[group.len] = quantified.items.len;

        var known: std.ArrayList(types.Meta) = .empty;
        defer known.deinit(self.gpa);
        try known.appendSlice(self.gpa, quantified.items);
        try known.appendSlice(self.gpa, env.items);

        const context = try self.groupContext(frames, quantified.items, known.items);
        defer self.gpa.free(context);

        var own: std.ArrayList(types.Meta) = .empty;
        defer own.deinit(self.gpa);
        for (group, spans, out, 0..) |t, span, *member, i| {
            const mentioned = quantified.items[bounds[i]..bounds[i + 1]];
            own.clearRetainingCapacity();
            try own.appendSlice(self.gpa, mentioned);
            for (context) |c| {
                free.clearRetainingCapacity();
                try self.subst.freeMetas(c.type, &free);
                for (free.items) |id| {
                    if (std.mem.indexOfScalar(types.Meta, quantified.items, id) == null) continue;
                    if (std.mem.indexOfScalar(types.Meta, own.items, id) == null) try own.append(self.gpa, id);
                }
            }
            // A scheme's constraints drop their origin span: the scheme
            // outlives the term that raised them, and a use site that
            // violates one reports at its own span instead.
            const scheme = self.subst.quantify(t, own.items, context) catch |err| switch (err) {
                error.TooManyVariables => blk: {
                    try self.report(.limit, span, .{ .too_many_variables = own.items.len });
                    break :blk types.Scheme{ .type = t };
                },
                error.OutOfMemory => |e| return e,
            };
            if (types.ambiguity(scheme)) |found| {
                const c = context[found.constraint];
                try self.report(.ambiguous_constraint, span, .{ .ambiguous = c });
            }
            member.* = .{
                .scheme = scheme,
                .metas = try self.builder.dupeSlice(types.Meta, own.items),
                .context = try self.builder.dupeSlice(types.TypeClassConstraint, context),
                .poisoned = self.subst.isPoisoned(t),
            };
        }
        return try self.builder.dupeSlice(types.Meta, quantified.items);
    }

    /// The group context of the wanteds of `frames`: each residual
    /// mentioning one of `quantified`, without duplicates or constraints
    /// another's superclasses imply, in order of first appearance. The
    /// caller owns the result.
    ///
    /// Reports a residual that mentions a metavariable outside `known` as
    /// ambiguous at its origin: no type of the group or its environment
    /// mentions it, so nothing can determine it.
    fn groupContext(
        self: *Inference,
        frames: []const u32,
        quantified: []const types.Meta,
        known: []const types.Meta,
    ) Error![]types.TypeClassConstraint {
        var context: std.ArrayList(types.TypeClassConstraint) = .empty;
        errdefer context.deinit(self.gpa);
        var residuals: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer residuals.deinit(self.gpa);

        for (frames) |f| {
            for (self.evidence.get(f).wanteds.items) |w| {
                residuals.clearRetainingCapacity();
                // A refuted wanted is reported when it is solved.
                _ = try classes.solve(self.gpa, &self.env.classes, w.class, w.type, self.subst, &.{}, classes.Check{ .collect = .{ .gpa = self.gpa, .out = &residuals } });
                for (residuals.items) |r| {
                    if (!try self.subst.within(r.type, known)) {
                        try self.report(.ambiguous_constraint, w.origin, .{ .ambiguous = r });
                        continue;
                    }
                    if (!try self.subst.mentionsAny(r.type, quantified)) continue;
                    const settled = try self.subst.resolveDeep(r.type);
                    for (context.items) |earlier| {
                        if (earlier.class == r.class and types.eql(earlier.type, settled)) break;
                    } else try context.append(self.gpa, .{ .class = r.class, .type = settled });
                }
            }
        }

        context.shrinkRetainingCapacity(try classes.prune(self.gpa, &self.env.classes, context.items, self.subst));
        return try context.toOwnedSlice(self.gpa);
    }

    /// `body`, a member of the group `bindings`, with each use of a member
    /// applied to `dictionaries`, the member's own dictionary parameters.
    /// Every member takes the group's context in one order, so a recursive
    /// use passes the dictionaries it was given.
    fn recursiveUses(
        self: *Inference,
        bindings: []const core.Letrec.Binding,
        dictionaries: []const core.SymbolId,
        body: core.Term,
    ) Error!core.Term {
        if (dictionaries.len == 0 or bindings.len == 0) return body;
        var uses: evidence.Replacements = .empty;
        defer uses.deinit(self.gpa);
        const arguments = try self.builder.slice(core.Term, dictionaries.len);
        for (dictionaries, arguments) |d, *argument| argument.* = self.builder.symbol(d, body.span);
        for (bindings) |b| {
            try uses.put(self.gpa, b.name, try self.builder.applyMany(self.builder.symbol(b.name, body.span), arguments, body.span));
        }
        return try evidence.substitute(self.builder, body, &uses);
    }

    /// Solves the wanteds of frame `at` against the givens in scope, binding
    /// each one's evidence there. A wanted already solved in `at` or a frame
    /// enclosing it shares that evidence. A wanted, or a residual of one,
    /// mentioning none of `quantified` floats to the enclosing frame. Reports
    /// each wanted no rule solves.
    fn solve(self: *Inference, at: u32, quantified: []const types.Meta) Error!void {
        var wanteds = self.evidence.takeAll(at);
        defer wanteds.deinit(self.gpa);
        for (wanteds.items) |w| {
            if (try self.floatsTo(at, w.type, quantified)) |parent| {
                try self.evidence.want(parent, w);
                continue;
            }
            const settled = try self.subst.resolveDeep(w.type);
            if (w.evidence) |symbol| if (self.evidence.solvedIn(at, w.class, settled)) |earlier| {
                try self.evidence.bind(at, symbol, self.builder.symbol(earlier, w.origin));
                continue;
            };
            switch (try self.solveOne(at, w, quantified)) {
                .solved => |e| if (w.evidence) |symbol| {
                    try self.evidence.bind(at, symbol, e.?);
                    try self.evidence.solve(at, .{ .class = w.class, .type = settled, .evidence = symbol });
                },
                .refuted => |culprit| try self.reportUnsolved(at, w, .{ .class = w.class, .type = culprit }, true),
                .stuck => |leaf| try self.reportUnsolved(at, w, leaf, false),
            }
        }
    }

    /// The frame enclosing `at`, when a wanted on `t` floats there: it
    /// mentions none of `quantified`.
    fn floatsTo(self: *Inference, at: u32, t: types.Type, quantified: []const types.Meta) Error!?u32 {
        const parent = self.evidence.get(at).parent orelse return null;
        if (try self.subst.mentionsAny(t, quantified)) return null;
        return parent;
    }

    fn solveOne(self: *Inference, at: u32, w: evidence.Wanted, quantified: []const types.Meta) Error!classes.Solution(?core.Term) {
        var givens: std.ArrayList(classes.Given(?core.Term)) = .empty;
        defer givens.deinit(self.gpa);
        try self.evidence.scope(self.builder, at, w.origin, &givens);
        const sink: evidence.Sink(Float) = .{
            .builder = self.builder,
            .env = self.env,
            .span = w.origin,
            .leaves = .{ .inference = self, .at = at, .quantified = quantified },
        };
        return try classes.solve(self.gpa, &self.env.classes, w.class, w.type, self.subst, givens.items, sink);
    }

    /// Floats a leaf to the enclosing frame, as a wanted of its own, when a
    /// wanted on it would float.
    const Float = struct {
        inference: *Inference,
        at: u32,
        quantified: []const types.Meta,

        pub fn leaf(self: Float, class: classes.ClassId, t: types.Type, span: diagnostic.Span) Error!??core.Term {
            const i = self.inference;
            const parent = try i.floatsTo(self.at, t, self.quantified) orelse return null;
            const symbol = try i.raise(parent, class, t, span);
            const term: ?core.Term = if (symbol) |s| i.builder.symbol(s, span) else null;
            return term;
        }
    };

    /// Reports `w`, which `needed` keeps from being solved in frame `at`:
    /// refuted by the instances, or a leaf nothing in scope solves.
    fn reportUnsolved(self: *Inference, at: u32, w: evidence.Wanted, needed: types.TypeClassConstraint, refuted: bool) Error!void {
        const frame = self.evidence.get(at);
        if (frame.instance) |id| {
            return try self.report(.invalid_instance, self.env.classes.instance(id).span, .{
                .superclass = .{ .instance = id, .needed = needed },
            });
        }
        if (refuted) return try self.report(.unsatisfied_constraint, w.origin, .{ .violation = needed });
        if (frame.signature) |span| return try self.report(.signature_mismatch, span, .{ .violation = needed });
        try self.report(.ambiguous_constraint, w.origin, .{ .ambiguous = needed });
    }

    /// Infers one strongly connected component of the definition graph
    /// leaving each member's generalized scheme in `inferred` and its
    /// elaborated body in `elaborated`.
    ///
    /// T-LetRec at top level: placeholders, bodies, unify, generalize
    /// together. Mutual recursion works because every member is in scope
    /// monomorphically while any body is checked. A member with a signature
    /// is a component of its own, and every use of it, its own included, is
    /// at the signature.
    ///
    /// `core.Program.components` is already in dependency order, so a callee's
    /// scheme is generalized before its caller's body is inferred. The library
    /// arrives in earlier components than user code and needs no special case.
    ///
    /// A member whose type is poisoned fails.
    pub fn component(
        self: *Inference,
        definitions: []const core.Definition,
        members: []const u32,
    ) Error!void {

        // A component is inferred as one letrec of its definitions.
        const bindings = try self.gpa.alloc(core.Letrec.Binding, members.len);
        defer self.gpa.free(bindings);
        var group = try Group.init(self.gpa, members.len);
        defer group.deinit(self.gpa);
        for (members, bindings, group.spans()) |index, *binding, *span| {
            const definition = definitions[index];
            binding.* = .{ .name = definition.symbol, .value = definition.body };
            span.* = definition.span;
        }
        var quantified = try self.inferGroup(bindings, &group);

        for (members, group.generalized(), group.frames(), group.bound()) |index, g, frame, *slot| {
            const symbol = definitions[index].symbol;

            // A written signature is checked against the inferred scheme, and
            // an accepted one becomes what is exported. Its context is the
            // body's givens, in its written order.
            if (self.env.annotationOf(symbol)) |declared| {
                try self.inferred.put(symbol, declared.scheme);
                self.evidence.get(frame).signature = declared.span;
                // A body its signature doesn't match is solved under its own
                // context, so its other errors are still found.
                const representatives = try self.checkAnnotation(g, declared.scheme, declared.span) orelse {
                    self.evidence.get(frame).signature = null;
                    slot.* = try self.parameters(frame, g.context);
                    continue;
                };
                const metas = try self.subst.arena.alloc(types.Type, representatives.len);
                for (representatives, metas) |id, *meta| meta.* = .{ .meta = id };
                const context = try self.subst.arena.alloc(types.TypeClassConstraint, declared.scheme.constraints.len);
                for (declared.scheme.constraints, context) |c, *constraint| {
                    constraint.* = .{ .class = c.class, .type = try self.subst.instantiateWith(c.type, metas) };
                }
                slot.* = try self.parameters(frame, context);
                quantified = representatives;
            } else {
                try self.inferred.put(symbol, g.scheme);
                if (g.poisoned) try self.failed.put(self.gpa, symbol, {});
                slot.* = try self.parameters(frame, g.context);
            }
        }
        for (group.frames()) |f| try self.solve(f, quantified);

        for (members, 0..) |index, i| {
            const definition = definitions[index];
            // A signed member is used at its signature, its own body included.
            const recursive = if (self.env.annotationOf(definition.symbol) == null) bindings else &.{};
            const elaborated = try self.close(&group, i, recursive);
            if (!core.same(elaborated, definition.body)) try self.elaborated.put(definition.symbol, elaborated);
        }
    }

    /// Every component in order. The whole program's inference.
    pub fn program(
        self: *Inference,
        definitions: []const core.Definition,
        components: []const []const u32,
    ) Error!void {
        for (components) |members| try self.component(definitions, members);
    }

    /// A linked program: every component, each instance's superclasses,
    /// then `main`'s three extra checks, then the wanteds left at the top.
    pub fn check(self: *Inference, p: *const core.Program) Error!void {
        self.entry = p.entry;
        try self.program(p.definitions, p.components);
        try self.superclasses();

        // Only after the body has a type, and spanning the whole definition
        // rather than the body.
        for (p.entryDefinitions()) |d| {
            if (d.symbol == p.entry) try self.checkMain(p.entry, d.span);
        }
        try self.solve(evidence.top, &.{});
    }

    /// Solves each superclass of each instance with a dictionary, in a frame
    /// whose givens are the instance's context.
    fn superclasses(self: *Inference) Error!void {
        const registry = &self.env.classes;
        for (registry.instances.items, 0..) |instance, i| {
            if (instance.dictionary == null) continue;
            const id: classes.InstanceId = @enumFromInt(i);
            const class = registry.get(instance.class);
            const frame = try self.evidence.frame(null);
            self.evidence.get(frame).instance = id;

            const context = try self.subst.arena.alloc(types.TypeClassConstraint, instance.context.len);
            for (instance.context, context) |r, *slot| slot.* = r.constraint();
            const dictionaries = try self.parameters(frame, context);

            const selected = try self.builder.slice(core.SymbolId, class.selectors.len);
            var next: usize = 0;
            for (class.superclasses) |super| {
                if (try self.raise(frame, super, instance.type, instance.span)) |s| {
                    selected[next] = s;
                    next += 1;
                }
            }
            try self.solve(frame, &.{});
            try self.instances.append(self.gpa, .{ .id = id, .frame = frame, .parameters = dictionaries, .superclasses = selected });
        }
    }

    /// The generalized scheme of a definition, once its component is done.
    pub fn schemeOf(self: *const Inference, id: core.SymbolId) ?types.Scheme {
        return self.inferred.get(id);
    }

    /// Checks the inferred scheme against a written signature.
    ///
    /// The declared type must be an *instance* of the inferred one: a
    /// signature may be more specific than the body supports. Binds each
    /// metavariable the inferred scheme quantified to what the signature
    /// makes of it, so the body's wanteds are over the signature's
    /// variables, and solving them against its context checks it.
    ///
    /// Returns the metavariable standing for each declared variable, or
    /// null when the signature does not match.
    fn checkAnnotation(
        self: *Inference,
        generalized: Generalized,
        declared: types.Scheme,
        span: diagnostic.Span,
    ) Error!?[]const types.Meta {
        const inferred = generalized.scheme;
        const before = self.subst.count();
        const rigid = try self.subst.instantiate(declared);
        const after = self.subst.count();

        const flexible = try self.subst.instantiate(inferred);

        switch (try unify.unify(self.subst, rigid.type, flexible.type)) {
            .unified => {},
            .mismatch => |m| {
                try self.report(.signature_mismatch, span, .{ .mismatch = m });
                return null;
            },
        }

        // What each declared variable resolved to. Each must still be an
        // unsolved metavariable, and no two may have become the same one.
        const representatives = try self.subst.arena.alloc(types.Meta, after - before);
        for (representatives, 0..) |*slot, i| {
            const id: types.Meta = @intCast(before + i);
            const resolved = self.subst.expand(.{ .meta = id });
            const still_arbitrary = resolved == .meta and
                (resolved.meta == id or resolved.meta >= after) and
                std.mem.indexOfScalar(types.Meta, representatives[0..i], resolved.meta) == null;
            if (!still_arbitrary) {
                try self.report(.signature_mismatch, span, .{
                    .mismatch = .{
                        .reason = .incompatible,
                        .expected = declared.type,
                        .found = inferred.type,
                    },
                });
                return null;
            }
            slot.* = resolved.meta;
        }

        for (generalized.metas, flexible.metas) |meta, instance| {
            switch (try unify.unify(self.subst, .{ .meta = meta }, instance)) {
                .unified => {},
                .mismatch => |m| {
                    try self.report(.signature_mismatch, span, .{ .mismatch = m });
                    return null;
                },
            }
        }
        return representatives;
    }

    /// `Filter input output`.
    fn filter(self: *Inference, input: types.Type, output: types.Type) Error!types.Type {
        const id = core.datatypes.ownerOf(&self.env.interner, self.env.known.get(.Filter).?).?;
        return try types.constructed(self.subst.arena, id, self.env.datatypes.get(id).name, &.{ input, output });
    }

    /// The `tau` of `Filter Node tau` once `t` is unified with it, or null,
    /// reported at `span`, when it cannot be.
    fn mainOutput(self: *Inference, t: types.Type, span: diagnostic.Span) Error!?types.Type {
        const output = try self.subst.fresh(.type);
        const wanted = try self.filter(types.node_type, output);
        switch (try unify.unify(self.subst, wanted, t)) {
            .unified => return output,
            .mismatch => |m| {
                try self.reportAbout(.main_type, span, .{ .mismatch = m }, &.{ wanted, t });
                return null;
            },
        }
    }

    /// `main`'s three extra checks. Its constraints are raised at the types
    /// `main` is run at, in the top frame, and `finish` applies it to their
    /// evidence.
    pub fn checkMain(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!void {
        if (self.failed.contains(id)) return;
        const scheme = self.inferred.get(id) orelse return;
        const instantiated = try self.instantiate(scheme, span);

        // 1. `Filter Node tau`
        const output = try self.mainOutput(instantiated.type, span) orelse return;

        // 2. `Serial tau`
        try self.evidence.want(evidence.top, .{ .class = .serial, .type = output, .evidence = null, .origin = span });

        // 3. Nothing may remain undetermined
        const settled = try self.subst.resolveDeep(output);
        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.subst.freeMetas(settled, &free);
        if (free.items.len > 0) return try self.report(.ambiguous_output, span, .{ .ambiguous_output = settled });

        try self.inferred.put(id, .{
            .type = try self.filter(types.node_type, settled),
        });
        self.entry_evidence = instantiated.evidence;
    }

    /// Replaces each definition's body in `linked` with its elaborated one,
    /// and appends the evidence solved at the top, the selectors, and the
    /// instance dictionaries.
    ///
    /// A `main` that takes dictionaries is renamed to a generated global, and
    /// `main` becomes that global applied to its evidence.
    pub fn finish(self: *Inference, linked: *core.Program) Error!void {
        if (self.elaborated.entries.items.len == 0) return;

        var definitions: std.ArrayList(core.Definition) = .empty;
        defer definitions.deinit(self.gpa);
        try definitions.ensureTotalCapacity(self.gpa, linked.definitions.len);
        var entry: ?core.Definition = null;
        for (linked.definitions) |d| {
            const body = self.elaborated.get(d.symbol) orelse d.body;
            if (d.symbol == linked.entry and self.entry_evidence.len > 0) {
                entry = try self.renameEntry(d, body);
                definitions.appendAssumeCapacity(.{
                    .symbol = d.symbol,
                    .body = try self.builder.applyMany(self.builder.symbol(entry.?.symbol, d.span), self.entry_evidence, d.span),
                    .span = d.span,
                });
                continue;
            }
            definitions.appendAssumeCapacity(.{ .symbol = d.symbol, .body = body, .span = d.span });
        }
        if (entry) |e| try definitions.append(self.gpa, e);
        const module = self.env.interner.moduleOf(linked.entry).?;
        for (self.evidence.get(evidence.top).bindings.items) |b| {
            self.env.interner.globalize(b.name, module);
            try definitions.append(self.gpa, .{ .symbol = b.name, .body = b.value, .span = b.value.span });
        }
        try evidence.dictionaries(self.builder, &self.env.classes, self.env, &self.evidence, self.instances.items, &definitions, self.gpa);
        linked.definitions = try self.builder.dupeSlice(core.Definition, definitions.items);
    }

    /// `main`'s definition under a generated name, its references to itself
    /// renamed.
    fn renameEntry(self: *Inference, d: core.Definition, body: core.Term) Error!core.Definition {
        const renamed = try self.env.interner.generate(
            self.env.interner.moduleOf(d.symbol).?,
            self.env.interner.spelling(d.symbol),
            .vanilla,
        );
        var rename: evidence.Replacements = .empty;
        defer rename.deinit(self.gpa);
        try rename.put(self.gpa, d.symbol, self.builder.symbol(renamed, d.span));
        return .{ .symbol = renamed, .body = try evidence.substitute(self.builder, body, &rename), .span = d.span };
    }

    /// Hands the scheme table to the caller, who becomes responsible for it.
    /// `deinit` must not free it afterwards, so it is left empty.
    fn takeSchemes(self: *Inference) core.SymbolTable(types.Scheme) {
        const taken = self.inferred;
        self.inferred = core.SymbolTable(types.Scheme).init(self.gpa);
        return taken;
    }

    /// Unifies, reporting a failure as a `type-mismatch` at `span`.
    fn expect(self: *Inference, found: types.Type, want: types.Type, span: diagnostic.Span) Error!void {
        switch (try unify.unify(self.subst, want, found)) {
            .unified => {},
            .mismatch => |m| try self.reportAbout(.type_mismatch, span, .{ .mismatch = m }, &.{ want, found }),
        }
    }

    /// Records an error at `span` about the types its detail names.
    fn report(
        self: *Inference,
        category: diagnostic.Category,
        span: diagnostic.Span,
        detail: Failure.Detail,
    ) Error!void {
        switch (detail) {
            .mismatch => |m| try self.reportAbout(category, span, detail, &.{ m.expected, m.found }),
            .violation, .ambiguous => |c| try self.reportAbout(category, span, detail, &.{c.type}),
            .superclass => |sc| try self.reportAbout(category, span, detail, &.{sc.needed.type}),
            .over_application, .not_a_function, .view_not_function, .ambiguous_output => |t| try self.reportAbout(category, span, detail, &.{t}),
            .unbound, .too_many_variables => try self.reportAbout(category, span, detail, &.{}),
        }
    }

    /// Records an error at `span` about `subjects`, unless one of them is
    /// poisoned, and poisons each. A mismatch's subjects are the types
    /// unified, not the parts of them it names, which are resolved and may
    /// have lost a poisoned metavariable.
    fn reportAbout(
        self: *Inference,
        category: diagnostic.Category,
        span: diagnostic.Span,
        detail: Failure.Detail,
        subjects: []const types.Type,
    ) Error!void {
        for (subjects) |t| if (self.subst.isPoisoned(t)) return;
        for (subjects) |t| self.subst.poison(t);
        try self.failures.append(self.gpa, .{
            .category = category,
            .span = span,
            .detail = detail,
        });
    }
};

/// Type-checks a linked program, reporting through `sink`.
///
/// Every insoluble wanted is reported, in source order, at its own span,
/// except one about a poisoned type. See Poisoned types in type_check.zig.
/// `main`'s shape is checked only after its body has a type, and a body
/// that failed to infer produces no `main-type` diagnostic on top.
pub fn check(
    gpa: Allocator,
    program: *core.Program,
    sink: *diagnostic.Sink,
) !void {
    // Every type inference builds lives here. Only the final schemes are
    // copied out into the environment.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    var subst = Substitution.init(gpa, scratch.allocator(), &program.env.datatypes, &program.env.classes);
    defer subst.deinit();

    var inference = try Inference.init(gpa, &subst, &program.env);
    defer inference.deinit();

    try inference.check(program);
    if (inference.failures.items.len > 0) {
        std.mem.sort(Failure, inference.failures.items, {}, inSourceOrder);
        for (inference.failures.items) |failure| try render(gpa, &subst, &program.env, failure, sink);
        return error.TypeCheckFailed;
    }
    try inference.finish(program);

    var found = inference.takeSchemes();
    defer found.deinit();
    try program.env.schemes.reserve(found.entries.items.len);
    var it = found.iterator();
    while (it.next()) |entry| {
        try program.env.setScheme(entry.id, try entry.value.clone(program.env.allocator()));
    }
}

fn inSourceOrder(_: void, a: Failure, b: Failure) bool {
    if (a.span.source != b.span.source) return @intFromEnum(a.span.source) < @intFromEnum(b.span.source);
    return a.span.start_byte < b.span.start_byte;
}

fn render(
    gpa: Allocator,
    subst: *Substitution,
    env: *core.env.Env,
    failure: Failure,
    sink: *diagnostic.Sink,
) !void {
    var buf: std.Io.Writer.Allocating = .init(sink.allocator);
    defer buf.deinit();

    switch (failure.detail) {
        .mismatch => |m| {
            const expected = try subst.resolveDeep(m.expected);
            const found = try subst.resolveDeep(m.found);
            var names = try env.messageNames(gpa, &.{ expected, found }, &.{});
            defer names.deinit(gpa);
            try buf.writer.print("Expected `{f}`, found `{f}`.", .{ expected.named(&names), found.named(&names) });
        },
        .violation => |v| {
            const t = try subst.resolveDeep(v.type);
            var names = try env.messageNames(gpa, &.{t}, &.{v.class});
            defer names.deinit(gpa);
            try buf.writer.print("`{f} {f}` is not satisfied.", .{ names.class(v.class, env.classes.spelling(v.class)), t.namedOperand(&names) });
        },
        .ambiguous => |c| {
            const t = try subst.resolveDeep(c.type);
            var names = try env.messageNames(gpa, &.{t}, &.{c.class});
            defer names.deinit(gpa);
            try buf.writer.print("`{f} {f}` is ambiguous: nothing determines its type.", .{ names.class(c.class, env.classes.spelling(c.class)), t.namedOperand(&names) });
        },
        .superclass => |s| {
            const instance = env.classes.instance(s.instance);
            const needed = try subst.resolveDeep(s.needed.type);
            var names = try env.messageNames(gpa, &.{ instance.type, needed }, &.{ instance.class, s.needed.class });
            defer names.deinit(gpa);
            try buf.writer.print("`{f} {f}` needs `{f} {f}`", .{
                names.class(instance.class, env.classes.spelling(instance.class)),
                instance.type.namedOperand(&names),
                names.class(s.needed.class, env.classes.spelling(s.needed.class)),
                needed.namedOperand(&names),
            });
        },
        inline .over_application, .view_not_function, .not_a_function, .ambiguous_output => |shown, tag| {
            const t = try subst.resolveDeep(shown);
            var names = try env.messageNames(gpa, &.{t}, &.{});
            defer names.deinit(gpa);
            const message = switch (tag) {
                .over_application => "`{f}` has no argument left to take.",
                .view_not_function => "The expression of a view pattern must be a function; found `{f}`.",
                .not_a_function => "`{f}` is not a function.",
                .ambiguous_output => "`main`'s output `{f}` is ambiguous: nothing determines its type.",
                else => comptime unreachable,
            };
            try buf.writer.print(message, .{t.named(&names)});
        },
        .unbound => |id| try buf.writer.print(
            "`{s}` is not defined.",
            .{env.interner.spelling(id)},
        ),
        .too_many_variables => |n| try buf.writer.print(
            "The type has {d} variables, more than the {d} a scheme can quantify.",
            .{ n, std.math.maxInt(types.TypeVar) },
        ),
    }

    try sink.report(failure.category, failure.span, "{s}", .{buf.written()});
}
