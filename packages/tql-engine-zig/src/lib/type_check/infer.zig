//! Algorithm W over Core, with a mutable substitution. Inference elaborates:
//! each term is rebuilt with dictionary passing made explicit.

const std = @import("std");
const constraints = @import("constraints.zig");
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
        violation: constraints.Violation,
        over_application: types.Type,
        unbound: core.SymbolId,
        too_many_variables: usize,
        ambiguous: types.TypeClassConstraint,
    };
};

pub const Error = error{TypeError} || Allocator.Error;

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
    undecided: *constraints.Set,
    scope: Scope,
    /// Schemes generalized so far, by symbol. An earlier SCC's result.
    inferred: core.SymbolTable(types.Scheme),
    /// Declared types and classes, written signatures, and every symbol.
    /// Placeholders and dictionary parameters are interned here.
    env: *core.env.Env,
    failure: ?Failure = null,
    /// Builds elaborated terms in the environment's arena.
    builder: core.Builder,
    evidence: evidence.Table,
    /// The generalized body being inferred.
    frame: ?u32 = null,
    /// Each top-level definition's elaborated body, where it differs from
    /// the written one. Its placeholders are resolved by `finish`.
    elaborated: core.SymbolTable(core.Term),
    /// The placeholders `main` is applied to.
    entry_evidence: []const core.Term = &.{},
    /// `main`, while a program is checked.
    entry: ?core.SymbolId = null,

    pub fn init(
        gpa: Allocator,
        subst: *Substitution,
        undecided: *constraints.Set,
        target: *core.env.Env,
    ) Inference {
        return .{
            .gpa = gpa,
            .subst = subst,
            .undecided = undecided,
            .env = target,
            .scope = Scope.init(gpa),
            .inferred = core.SymbolTable(types.Scheme).init(gpa),
            .builder = .{ .allocator = target.allocator() },
            .evidence = evidence.Table.init(gpa),
            .elaborated = core.SymbolTable(core.Term).init(gpa),
        };
    }

    pub fn deinit(self: *Inference) void {
        self.elaborated.deinit();
        self.evidence.deinit();
        self.inferred.deinit();
        self.scope.deinit();
    }

    /// The type of `term` under the current environment.
    pub fn term(self: *Inference, t: core.Term) Error!types.Type {
        return (try self.elaborate(t)).type;
    }

    /// A term's type, and the term with each use of a constrained name
    /// applied to placeholders for its evidence and each generalized `let`
    /// abstracted over its dictionaries. A subterm with nothing to elaborate
    /// is shared.
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
        /// One placeholder per dictionary constraint, in the scheme's order.
        evidence: []const core.Term,
    };

    /// Instantiating a scheme also raises its constraints, on the fresh
    /// metavariables its bound variables became, and leaves a placeholder for
    /// each one with dictionary evidence.
    fn instantiate(self: *Inference, scheme: types.Scheme, span: diagnostic.Span) Error!Instantiated {
        const inst = try self.subst.instantiate(scheme);
        var placeholders: std.ArrayList(core.Term) = .empty;
        for (scheme.constraints) |c| {
            const on = try self.subst.instantiateWith(c.type, inst.metas);
            if (try self.undecided.require(self.subst, c.class, on, span)) |v| {
                return self.fail(.unsatisfied_constraint, span, .{ .violation = v });
            }
            if (self.env.classes.evidenceOf(c.class) != .dictionary) continue;
            try placeholders.append(self.builder.allocator, try self.placeholder(span, .{ .constraint = .{ .class = c.class, .type = on } }));
        }
        return .{ .type = inst.type, .evidence = placeholders.items };
    }

    fn placeholder(self: *Inference, span: diagnostic.Span, wanted: evidence.Placeholder.Wanted) Error!core.Term {
        const symbol = try self.env.interner.fresh("evidence");
        try self.evidence.want(.{ .symbol = symbol, .frame = self.frame, .span = span, .wanted = wanted });
        return self.builder.symbol(symbol, span);
    }

    /// A use of `id` at a fresh instance of `scheme`.
    fn occurrence(self: *Inference, id: core.SymbolId, scheme: types.Scheme, span: diagnostic.Span) Error!Elaborated {
        const inst = try self.instantiate(scheme, span);
        return .{
            .type = inst.type,
            .term = try self.builder.applyMany(self.builder.symbol(id, span), inst.evidence, span),
        };
    }

    /// Binds one dictionary parameter per constraint of `wanted`, in order,
    /// as givens of `frame`.
    fn parameters(self: *Inference, frame: u32, wanted: []const types.TypeClassConstraint) Error![]const core.SymbolId {
        const bound = try self.builder.slice(core.SymbolId, wanted.len);
        for (wanted, bound) |c, *parameter| {
            parameter.* = try self.env.interner.fresh("d");
            try self.evidence.give(frame, .{ .class = c.class, .type = c.type, .evidence = parameter.* });
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
    fn variable(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!Elaborated {
        if (self.env.annotationOf(id)) |declared| return try self.occurrence(id, declared.scheme, span);
        if (self.scope.lookup(id)) |binding| return switch (binding) {
            // Monomorphic: used at one type, not instantiated.
            .monomorphic => |t| .{ .type = t, .term = self.builder.symbol(id, span) },
            .member => |t| .{ .type = t, .term = try self.placeholder(span, .{ .member = id }) },
            .scheme => |s| try self.occurrence(id, s, span),
        };
        if (self.inferred.get(id)) |s| return try self.occurrence(id, s, span);
        if (self.env.schemeOf(id)) |s| return try self.occurrence(id, s, span);
        return self.fail(.unresolved_name, span, .{ .unbound = id });
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
            .term = if (evidence.same(body.term, lam.body)) t else try self.builder.lambda(lam.parameter, body.term, t.span),
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

        // This isn't and can never be a function. Therefore we're over applying.
        const head = self.subst.resolve(callee);
        const expanded = self.subst.expand(head);
        if (expanded != .function and expanded != .meta) {
            return self.fail(
                .over_application,
                app.argument.span,
                .{ .over_application = head },
            );
        }

        const result = try self.subst.fresh(.type);
        const arrow = try types.func(self.subst.arena, argument, result);

        switch (try unify.unify(self.subst, callee, arrow)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .type_mismatch,
                app.argument.span,
                .{ .mismatch = m },
            ),
        }

        try self.recheck();
        const unchanged = evidence.same(function.term, app.function) and evidence.same(operand.term, app.argument);
        return .{
            .type = result,
            .term = if (unchanged) t else try self.builder.apply(function.term, operand.term, t.span),
        };
    }

    /// (T-If)        Gamma |- e_c : bool
    ///               Gamma |- e_t : tau
    ///               Gamma |- e_f : tau
    ///               --------------------------------------------
    ///               Gamma |- if e_c then e_t else e_f : tau
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

        var first: ?Branch = null;
        var alternatives: evidence.Rebuilt(core.Case.Alternative) = .{ .original = c.alternatives };
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
            }, !evidence.same(elaborated_body.term, alternative.body));
            try self.joinBranch(&first, elaborated_body.type, alternative.body.span);
        }

        var default = c.default;
        if (c.default) |body| {
            const elaborated_default = try self.elaborate(body);
            default = elaborated_default.term;
            try self.joinBranch(&first, elaborated_default.type, body.span);
        }

        const unchanged = alternatives.copy == null and
            evidence.same(elaborated_scrutinee.term, c.scrutinee) and
            evidence.sameOptional(default, c.default);
        return .{
            .type = first.?.type,
            .term = if (unchanged) t else try self.builder.caseWithDefault(
                elaborated_scrutinee.term,
                alternatives.copy orelse c.alternatives,
                default,
                t.span,
            ),
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
        try self.generalizeGroup(&.{elaborated_value.type}, &.{l.value.span}, false, &generalized);
        const bound = try self.parameters(frame, generalized[0].dictionaries);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(l.name, .{ .scheme = generalized[0].scheme });
        const body = try self.elaborate(l.body);

        const new_value = try self.builder.abstract(bound, elaborated_value.term);
        const unchanged = evidence.same(new_value, l.value) and evidence.same(body.term, l.body);
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

        const unchanged = evidence.same(value.term, l.value) and evidence.same(body.term, l.body);
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

        const generalized = try self.gpa.alloc(Generalized, l.bindings.len);
        defer self.gpa.free(generalized);
        const spans = try self.gpa.alloc(diagnostic.Span, l.bindings.len);
        defer self.gpa.free(spans);
        const frames = try self.gpa.alloc(u32, l.bindings.len);
        defer self.gpa.free(frames);
        const values = try self.gpa.alloc(core.Term, l.bindings.len);
        defer self.gpa.free(values);
        for (l.bindings, spans) |b, *span| span.* = b.value.span;
        try self.inferGroup(l.bindings, spans, frames, values, generalized);

        var bindings: evidence.Rebuilt(core.Letrec.Binding) = .{ .original = l.bindings };
        for (l.bindings, generalized, frames, values, 0..) |b, g, frame, value, i| {
            const bound = try self.parameters(frame, g.dictionaries);
            const abstracted = try self.builder.abstract(bound, value);
            try bindings.set(self.builder, i, .{ .name = b.name, .value = abstracted }, !evidence.same(abstracted, b.value));
            try self.scope.push(b.name, .{ .scheme = g.scheme });
        }
        const body = try self.elaborate(l.body);
        const unchanged = bindings.copy == null and evidence.same(body.term, l.body);
        return .{
            .type = body.type,
            .term = if (unchanged) t else try self.builder.letrec(bindings.copy orelse l.bindings, body.term, t.span),
        };
    }

    /// Infer a group of mutually recursive bindings and generalize them
    /// together, writing each one's generalization to `out`, the frame its
    /// body was elaborated in to `frames`, and its elaborated body to
    /// `values`. Generalization reports against `spans`, one per binding.
    ///
    /// Each member's dictionary constraints are recorded as what a use of it
    /// within the group passes.
    fn inferGroup(
        self: *Inference,
        bindings: []const core.Letrec.Binding,
        spans: []const diagnostic.Span,
        frames: []u32,
        values: []core.Term,
        out: []Generalized,
    ) Error!void {
        const placeholders = try self.gpa.alloc(types.Type, bindings.len);
        defer self.gpa.free(placeholders);
        for (placeholders) |*p| p.* = try self.subst.fresh(.type);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        for (bindings, placeholders) |b, p| {
            try self.scope.push(b.name, .{ .member = p });
        }

        // Each inferred body must unify with its placeholder.
        const enclosing = self.frame;
        defer self.frame = enclosing;
        for (bindings, placeholders, frames, values) |b, p, *frame, *value| {
            frame.* = try self.evidence.frame(enclosing);
            self.frame = frame.*;
            const inferred = try self.elaborate(b.value);
            try self.expect(inferred.type, p, b.value.span);
            value.* = inferred.term;
        }

        // `main` is checked at `Node -> [tau]` before it generalizes, so it
        // quantifies over nothing that type determines.
        for (bindings, placeholders, spans) |b, p, span| {
            if (b.name == self.entry) _ = try self.mainOutput(p, span);
        }

        // Generalize against the environment *outside* the group, so the
        // placeholders being dropped is what lets them be quantified.
        self.scope.truncate(mark);
        try self.generalizeGroup(placeholders, spans, enclosing == null, out);
        for (bindings, out) |b, g| {
            if (g.dictionaries.len > 0) try self.evidence.parameters.put(b.name, g.dictionaries);
        }
    }

    /// One member's generalization.
    pub const Generalized = struct {
        scheme: types.Scheme,
        /// The metavariables the scheme's bound variables were, in order.
        metas: []const types.Meta,
        /// The constraints with dictionary evidence the member takes, over
        /// those metavariables, in parameter order.
        dictionaries: []const types.TypeClassConstraint,
    };

    /// `Gen(Gamma, tau_i)` for every member of a group checked together.
    ///
    /// Each member quantifies the metavariables free in its own type but not
    /// in the environment. A constraint with built-in evidence goes to each
    /// member whose own metavariables it mentions.
    ///
    /// Constraints with dictionary evidence are the group's one context: each
    /// is reduced through instances to constraints on bare metavariables,
    /// exact duplicates and those a superclass of another implies are
    /// dropped, and every member takes what remains, quantifying the
    /// metavariables it mentions. A residual on a metavariable no member
    /// quantifies is still owed by an enclosing scope.
    ///
    /// A top-level group first defaults what nothing can determine.
    ///
    /// Preconditions:
    /// - `spans.len == group.len`
    /// - `out.len == group.len`
    fn generalizeGroup(
        self: *Inference,
        group: []const types.Type,
        spans: []const diagnostic.Span,
        top_level: bool,
        out: []Generalized,
    ) Error!void {
        try self.recheck();

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

        if (top_level) try self.defaultAmbiguous(quantified.items);

        var taken: std.ArrayList(constraints.Constraint) = .empty;
        defer taken.deinit(self.gpa);
        try self.undecided.partitionByMetas(self.subst, quantified.items, &taken, self.gpa);

        const context = try self.groupContext(taken.items, quantified.items);
        defer self.gpa.free(context);

        // A scheme's constraints drop their origin span: the scheme outlives
        // the term that raised them, and a use site that violates one reports
        // at its own span instead.
        var bare: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer bare.deinit(self.gpa);
        var own: std.ArrayList(types.Meta) = .empty;
        defer own.deinit(self.gpa);
        for (group, spans, out, 0..) |t, span, *member, i| {
            const mentioned = quantified.items[bounds[i]..bounds[i + 1]];
            own.clearRetainingCapacity();
            try own.appendSlice(self.gpa, mentioned);
            bare.clearRetainingCapacity();
            for (context) |c| {
                free.clearRetainingCapacity();
                try self.subst.freeMetas(c.type, &free);
                for (free.items) |id| {
                    if (std.mem.indexOfScalar(types.Meta, quantified.items, id) == null) continue;
                    if (std.mem.indexOfScalar(types.Meta, own.items, id) == null) try own.append(self.gpa, id);
                }
                try bare.append(self.gpa, c);
            }
            for (taken.items) |c| {
                if (self.env.classes.evidenceOf(c.class) != .builtin) continue;
                if (!try self.subst.mentionsAny(c.type, mentioned)) continue;
                if (try self.implied(c, context)) continue;
                try bare.append(self.gpa, .{ .class = c.class, .type = c.type });
            }
            member.* = .{
                .scheme = self.subst.quantify(t, own.items, bare.items) catch |err| switch (err) {
                    error.TooManyVariables => return self.fail(.limit, span, .{
                        .too_many_variables = own.items.len,
                    }),
                    error.OutOfMemory => |e| return e,
                },
                .metas = try self.builder.dupeSlice(types.Meta, own.items),
                .dictionaries = try self.builder.dupeSlice(types.TypeClassConstraint, context),
            };
        }
    }

    /// Binds to `List` each metavariable of `List`'s kind that an undecided
    /// constraint mentions and `kept` lacks, when no constraint mentioning it
    /// fails at `List`, then rechecks the undecided constraints.
    fn defaultAmbiguous(self: *Inference, kept: []const types.Meta) Error!void {
        const list = try types.constructed(self.subst.arena, self.subst.datatypes.listId(), types.list_spelling, &.{});
        const kind = try unify.kindOf(self.subst, list);

        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        for (self.undecided.all()) |c| try self.subst.freeMetas(c.type, &free);

        var bound = false;
        for (free.items) |id| {
            if (std.mem.indexOfScalar(types.Meta, kept, id) != null) continue;
            if (!self.subst.kindOf(id).eql(kind)) continue;
            const holds = for (self.undecided.all()) |c| {
                if (!try self.subst.mentionsAny(c.type, &.{id})) continue;
                const at_list = try self.subst.assigned(c.type, id, list);
                if (try constraints.entails(self.subst, c.class, at_list) == .fails) break false;
            } else true;
            if (!holds) continue;
            self.subst.bind(id, list);
            bound = true;
        }
        if (bound) try self.recheck();
    }

    /// Re-decides the undecided constraints, failing at the first that no
    /// longer holds.
    fn recheck(self: *Inference) Error!void {
        if (try self.undecided.recheck(self.subst)) |v| {
            return self.fail(.unsatisfied_constraint, v.origin, .{ .violation = v });
        }
    }

    /// The group context `taken` reduces to: each constraint with dictionary
    /// evidence in head-normal form, mentioning one of `quantified`, without
    /// duplicates or constraints another's superclasses imply, in order of
    /// first appearance. Residuals mentioning none go back to `undecided`.
    /// The caller owns the result.
    fn groupContext(
        self: *Inference,
        taken: []const constraints.Constraint,
        quantified: []const types.Meta,
    ) Error![]types.TypeClassConstraint {
        var context: std.ArrayList(types.TypeClassConstraint) = .empty;
        errdefer context.deinit(self.gpa);
        var residuals: std.ArrayList(constraints.Residual) = .empty;
        defer residuals.deinit(self.gpa);

        for (taken) |c| {
            if (self.env.classes.evidenceOf(c.class) != .dictionary) continue;
            residuals.clearRetainingCapacity();
            if (try constraints.reduce(self.subst, c.class, c.type, &residuals, self.gpa)) |culprit| {
                return self.fail(.unsatisfied_constraint, c.origin, .{ .violation = .{
                    .class = c.class,
                    .type = culprit,
                    .origin = c.origin,
                } });
            }
            for (residuals.items) |r| {
                if (!try self.subst.mentionsAny(r.type, quantified)) {
                    _ = try self.undecided.require(self.subst, r.class, r.type, c.origin);
                    continue;
                }
                const settled = try self.subst.resolveDeep(r.type);
                for (context.items) |earlier| {
                    if (earlier.class == r.class and types.eql(earlier.type, settled)) break;
                } else try context.append(self.gpa, .{ .class = r.class, .type = settled });
            }
        }

        context.shrinkRetainingCapacity(self.env.classes.pruneEntailed(context.items));
        return try context.toOwnedSlice(self.gpa);
    }

    /// Whether `c`, a constraint with built-in evidence, is implied by a
    /// superclass of a constraint in `context`.
    fn implied(self: *Inference, c: constraints.Constraint, context: []const types.TypeClassConstraint) Error!bool {
        return self.env.classes.entailedBy(context, .{ .class = c.class, .type = try self.subst.resolveDeep(c.type) });
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
    /// `desugar.Program.components` is already in dependency order, so a callee's
    /// scheme is generalized before its caller's body is inferred. The library
    /// arrives in earlier components than user code and needs no special case.
    pub fn component(
        self: *Inference,
        definitions: []const core.Definition,
        members: []const u32,
    ) Error!void {
        // A component is inferred as one letrec of its definitions.
        const bindings = try self.gpa.alloc(core.Letrec.Binding, members.len);
        defer self.gpa.free(bindings);
        const spans = try self.gpa.alloc(diagnostic.Span, members.len);
        defer self.gpa.free(spans);
        for (members, bindings, spans) |index, *binding, *span| {
            const definition = definitions[index];
            binding.* = .{ .name = definition.symbol, .value = definition.body };
            span.* = definition.span;
        }
        const generalized = try self.gpa.alloc(Generalized, members.len);
        defer self.gpa.free(generalized);
        const frames = try self.gpa.alloc(u32, members.len);
        defer self.gpa.free(frames);
        const bodies = try self.gpa.alloc(core.Term, members.len);
        defer self.gpa.free(bodies);
        const raised_before = self.evidence.placeholders.items.len;
        try self.inferGroup(bindings, spans, frames, bodies, generalized);
        const raised = self.evidence.placeholders.items.len > raised_before;

        for (members, generalized, frames, bodies) |index, g, frame, body| {
            const definition = definitions[index];
            const symbol = definition.symbol;

            // A written signature is checked against the inferred scheme, and
            // an accepted one becomes what is exported. Its context fixes the
            // dictionaries the definition takes, in its written order.
            const bound = if (self.env.annotationOf(symbol)) |declared| blk: {
                const representatives = try self.checkAnnotation(g, declared.scheme, declared.span, raised);
                defer self.gpa.free(representatives);
                try self.inferred.put(symbol, declared.scheme);
                var wanted: std.ArrayList(types.TypeClassConstraint) = .empty;
                defer wanted.deinit(self.gpa);
                const metas = try self.gpa.alloc(types.Type, representatives.len);
                defer self.gpa.free(metas);
                for (representatives, metas) |id, *slot| slot.* = .{ .meta = id };
                for (declared.scheme.constraints) |c| {
                    if (self.env.classes.evidenceOf(c.class) != .dictionary) continue;
                    try wanted.append(self.gpa, .{ .class = c.class, .type = try self.subst.instantiateWith(c.type, metas) });
                }
                break :blk try self.parameters(frame, wanted.items);
            } else blk: {
                try self.inferred.put(symbol, g.scheme);
                break :blk try self.parameters(frame, g.dictionaries);
            };

            const elaborated = try self.builder.abstract(bound, body);
            if (!evidence.same(elaborated, definition.body)) try self.elaborated.put(symbol, elaborated);
        }

        try self.rejectAmbiguous();
    }

    /// Fails on a constraint with dictionary evidence still undecided once a
    /// top-level component is generalized.
    fn rejectAmbiguous(self: *Inference) Error!void {
        for (self.undecided.all()) |c| {
            if (self.env.classes.evidenceOf(c.class) != .dictionary) continue;
            return self.fail(.ambiguous_constraint, c.origin, .{ .ambiguous = .{ .class = c.class, .type = c.type } });
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

    /// A linked program: every component, then `main`'s three extra checks.
    pub fn check(self: *Inference, p: *const core.Program) Error!void {
        self.entry = p.entry;
        defer self.entry = null;
        try self.program(p.definitions, p.components);

        // Only after the body has a type, and spanning the whole definition
        // rather than the body.
        const entry = for (p.entryDefinitions()) |d| {
            if (d.symbol == p.entry) break d;
        } else return;
        try self.checkMain(p.entry, entry.span);
    }

    /// The generalized scheme of a definition, once its component is done.
    pub fn schemeOf(self: *const Inference, id: core.SymbolId) ?types.Scheme {
        return self.inferred.get(id);
    }

    /// Checks the inferred scheme against a written signature.
    ///
    /// The declared type must be an *instance* of the inferred one: a
    /// signature may be more specific than the body supports. Its context must
    /// entail every constraint the body raises on a declared variable,
    /// directly or through superclasses.
    ///
    /// When `raised`, binds each metavariable the inferred scheme quantified
    /// to what the signature makes of it, so the body's placeholders are
    /// over the signature's variables.
    ///
    /// Returns the metavariable standing for each declared variable. The
    /// caller owns the result.
    fn checkAnnotation(
        self: *Inference,
        generalized: Generalized,
        declared: types.Scheme,
        span: diagnostic.Span,
        raised: bool,
    ) Error![]const types.Meta {
        const inferred = generalized.scheme;
        const before = self.subst.count();
        const rigid = try self.subst.instantiate(declared);
        const after = self.subst.count();

        const flexible = try self.subst.instantiate(inferred);

        switch (try unify.unify(self.subst, rigid.type, flexible.type)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .signature_mismatch,
                span,
                .{ .mismatch = m },
            ),
        }

        // What each declared variable resolved to. Each must still be an
        // unsolved metavariable, and no two may have become the same one.
        const representatives = try self.gpa.alloc(types.Meta, after - before);
        errdefer self.gpa.free(representatives);
        for (representatives, 0..) |*slot, i| {
            const id: types.Meta = @intCast(before + i);
            const resolved = self.subst.expand(.{ .meta = id });
            const still_arbitrary = resolved == .meta and
                (resolved.meta == id or resolved.meta >= after) and
                std.mem.indexOfScalar(types.Meta, representatives[0..i], resolved.meta) == null;
            if (!still_arbitrary) {
                return self.fail(.signature_mismatch, span, .{
                    .mismatch = .{
                        .reason = .incompatible,
                        .expected = declared.type,
                        .found = inferred.type,
                    },
                });
            }
            slot.* = resolved.meta;
        }

        // Each constraint the body raised, in head-normal form. One over
        // declared variables only must be entailed by the declared context,
        // and any other is still owed.
        var residuals: std.ArrayList(constraints.Residual) = .empty;
        defer residuals.deinit(self.gpa);
        for (inferred.constraints) |c| {
            const on = try self.subst.instantiateWith(c.type, flexible.metas);
            residuals.clearRetainingCapacity();
            if (try constraints.reduce(self.subst, c.class, on, &residuals, self.gpa)) |culprit| {
                return self.fail(.unsatisfied_constraint, span, .{ .violation = .{
                    .class = c.class,
                    .type = culprit,
                    .origin = span,
                } });
            }
            for (residuals.items) |r| {
                const over = try self.subst.abstractOver(r.type, representatives) orelse {
                    if (try self.undecided.require(self.subst, r.class, r.type, span)) |v| {
                        return self.fail(.unsatisfied_constraint, span, .{ .violation = v });
                    }
                    continue;
                };
                const wanted: types.TypeClassConstraint = .{ .class = r.class, .type = over };
                if (!self.env.classes.entailedBy(declared.constraints, wanted)) {
                    return self.fail(.signature_mismatch, span, .{ .violation = .{
                        .class = wanted.class,
                        .type = wanted.type,
                        .origin = span,
                    } });
                }
            }
        }

        if (raised) {
            for (generalized.metas, flexible.metas) |meta, instance| {
                switch (try unify.unify(self.subst, .{ .meta = meta }, instance)) {
                    .unified => {},
                    .mismatch => |m| return self.fail(.signature_mismatch, span, .{ .mismatch = m }),
                }
            }
        }
        return representatives;
    }

    /// `main`'s three extra checks. Its constraints are raised at the types
    /// `main` is run at, and `finish` applies it to their evidence.
    /// The `tau` of `Node -> [tau]` once `t` is unified with it, failing at
    /// `span` when it cannot be.
    fn mainOutput(self: *Inference, t: types.Type, span: diagnostic.Span) Error!types.Type {
        const output = try self.subst.fresh(.type);
        const wanted = try self.subst.datatypes.filter(self.subst.arena, types.node_type, output);
        switch (try unify.unify(self.subst, wanted, t)) {
            .unified => return output,
            .mismatch => |m| return self.fail(.main_type, span, .{ .mismatch = m }),
        }
    }

    pub fn checkMain(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!void {
        const scheme = self.inferred.get(id) orelse return;
        const instantiated = try self.instantiate(scheme, span);

        // 1. `Node -> [tau]`
        const output = try self.mainOutput(instantiated.type, span);

        try self.defaultAmbiguous(&.{});

        // 2. `Serial tau`
        if (try self.undecided.require(self.subst, .serial, output, span)) |v| {
            return self.fail(.unsatisfied_constraint, span, .{ .violation = v });
        }
        try self.recheck();

        // 3. Nothing may remain undetermined
        const settled = try self.subst.resolveDeep(output);

        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.subst.freeMetas(settled, &free);

        if (free.items.len > 0 or self.undecided.all().len > 0) {
            return self.fail(.ambiguous_output, span, .{
                .mismatch = .{
                    .reason = .incompatible,
                    .expected = types.node_type,
                    .found = try self.subst.resolveDeep(output),
                },
            });
        }

        try self.inferred.put(id, .{
            .type = try self.subst.datatypes.filter(self.subst.arena, types.node_type, settled),
        });

        self.entry_evidence = instantiated.evidence;
    }

    /// Resolves every placeholder, and replaces each definition's body in
    /// `linked` with its elaborated one. Appends the selectors and instance
    /// dictionaries those bodies refer to.
    ///
    /// A `main` that takes dictionaries is renamed to a generated global, and
    /// `main` becomes that global applied to its evidence.
    pub fn finish(self: *Inference, linked: *core.Program) Error!void {
        if (self.elaborated.entries.items.len == 0) return;

        var replacements: evidence.Replacements = .empty;
        defer replacements.deinit(self.gpa);
        var resolver: evidence.Resolver = .{
            .table = &self.evidence,
            .subst = self.subst,
            .registry = &self.env.classes,
            .env = self.env,
            .builder = self.builder,
            .gpa = self.gpa,
        };

        var definitions: std.ArrayList(core.Definition) = .empty;
        defer definitions.deinit(self.gpa);
        try definitions.ensureTotalCapacity(self.gpa, linked.definitions.len);
        (blk: {
            resolver.resolveAll(&replacements) catch |err| break :blk err;
            var entry: ?core.Definition = null;
            for (linked.definitions) |d| {
                const body = if (self.elaborated.get(d.symbol)) |elaborated|
                    try evidence.substitute(self.builder, elaborated, &replacements)
                else
                    d.body;
                if (d.symbol == linked.entry and self.entry_evidence.len > 0) {
                    entry = try self.renameEntry(d, body);
                    const arguments = try self.gpa.alloc(core.Term, self.entry_evidence.len);
                    defer self.gpa.free(arguments);
                    for (self.entry_evidence, arguments) |e, *argument| argument.* = try evidence.substitute(self.builder, e, &replacements);
                    definitions.appendAssumeCapacity(.{
                        .symbol = d.symbol,
                        .body = try self.builder.applyMany(self.builder.symbol(entry.?.symbol, d.span), arguments, d.span),
                        .span = d.span,
                    });
                    continue;
                }
                definitions.appendAssumeCapacity(.{ .symbol = d.symbol, .body = body, .span = d.span });
            }
            if (entry) |e| try definitions.append(self.gpa, e);
            resolver.dictionaries(self.env, &definitions) catch |err| break :blk err;
        }) catch |err| switch (err) {
            error.Unresolved => return self.failUnresolved(resolver.unresolved.?),
            else => |e| return e,
        };
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

    fn failUnresolved(self: *Inference, u: evidence.Unresolved) Error {
        return switch (u.reason) {
            .ambiguous => self.fail(.ambiguous_constraint, u.span, .{ .ambiguous = u.constraint }),
            .unsatisfied => self.fail(.unsatisfied_constraint, u.span, .{ .violation = .{
                .class = u.constraint.class,
                .type = u.constraint.type,
                .origin = u.span,
            } }),
        };
    }

    /// Hands the scheme table to the caller, who becomes responsible for it.
    /// `deinit` must not free it afterwards, so it is left empty.
    fn takeSchemes(self: *Inference) core.SymbolTable(types.Scheme) {
        const taken = self.inferred;
        self.inferred = core.SymbolTable(types.Scheme).init(self.gpa);
        return taken;
    }

    /// Unifies, converting a failure into a `type-mismatch` at `span`.
    fn expect(self: *Inference, found: types.Type, want: types.Type, span: diagnostic.Span) Error!void {
        switch (try unify.unify(self.subst, want, found)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .type_mismatch,
                span,
                .{ .mismatch = m },
            ),
        }
    }

    fn fail(
        self: *Inference,
        category: diagnostic.Category,
        span: diagnostic.Span,
        detail: Failure.Detail,
    ) Error {
        self.failure = .{
            .category = category,
            .span = span,
            .detail = detail,
        };
        return error.TypeError;
    }
};

/// Type-checks a linked program, reporting through `sink`.
///
/// Inference is bottom-up: the first unification failure is reported at
/// its own span, and `main`'s shape is checked only after its body has a type.
/// A body that failed to infer produces no `main-type` diagnostic on top.
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
    var undecided = constraints.Set.init(gpa);
    defer undecided.deinit();

    var inference = Inference.init(gpa, &subst, &undecided, &program.env);
    defer inference.deinit();

    (blk: {
        inference.check(program) catch |err| break :blk err;
        inference.finish(program) catch |err| break :blk err;
    }) catch |err| switch (err) {
        error.TypeError => {
            const failure = inference.failure.?;

            var buf: std.Io.Writer.Allocating = .init(sink.allocator);
            defer buf.deinit();

            var names: types.MetaNames = .{};
            switch (failure.detail) {
                .mismatch => |m| {
                    const expected = try subst.resolveDeep(m.expected);
                    const found = try subst.resolveDeep(m.found);
                    try buf.writer.print("Expected `{f}`, found `{f}`.", .{
                        expected.named(&names),
                        found.named(&names),
                    });
                },
                .violation => |v| try buf.writer.print(
                    "`{s} {f}` is not satisfied.",
                    .{ program.env.classes.spelling(v.class), (try subst.resolveDeep(v.type)).namedOperand(&names) },
                ),
                .over_application => |t| try buf.writer.print(
                    "`{f}` has no argument left to take.",
                    .{(try subst.resolveDeep(t)).named(&names)},
                ),
                .unbound => |id| try buf.writer.print(
                    "`{s}` is not defined.",
                    .{program.env.interner.spelling(id)},
                ),
                .too_many_variables => |n| try buf.writer.print(
                    "The type has {d} variables, more than the {d} a scheme can quantify.",
                    .{ n, std.math.maxInt(types.TypeVar) },
                ),
                .ambiguous => |c| try buf.writer.print(
                    "`{s} {f}` is ambiguous: nothing determines its type.",
                    .{ program.env.classes.spelling(c.class), (try subst.resolveDeep(c.type)).namedOperand(&names) },
                ),
            }

            try sink.report(failure.category, failure.span, "{s}", .{buf.written()});
            return error.TypeCheckFailed;
        },
        else => |e| return e,
    };

    var found = inference.takeSchemes();
    defer found.deinit();
    try program.env.schemes.reserve(found.entries.items.len);
    var it = found.iterator();
    while (it.next()) |entry| {
        try program.env.setScheme(entry.id, try entry.value.clone(program.env.allocator()));
    }
}
