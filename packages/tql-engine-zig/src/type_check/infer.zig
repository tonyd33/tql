//! Algorithm W over Core, with a mutable substitution.

const std = @import("std");
const constraints = @import("constraints.zig");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const schemes = @import("schemes.zig");
const types = core.types;
const unify = @import("unify.zig");

const Allocator = std.mem.Allocator;
const Substitution = @import("substitution.zig").Substitution;

/// The typing judgement a step concluded under. Carried so a failure can name
/// the rule it violated.
pub const Rule = enum {
    t_var,
    t_lit,
    t_lam,
    t_app,
    t_case,
    t_letrec,
    t_bind,
};

pub const Failure = struct {
    category: diagnostic.Category,
    span: diagnostic.Span,
    rule: Rule,
    detail: Detail,

    pub const Detail = union(enum) {
        mismatch: unify.Mismatch,
        violation: constraints.Violation,
        over_application: types.Type,
        unbound: core.SymbolId,
        too_many_variables: usize,
    };
};

pub const Error = error{TypeError} || schemes.Error;

/// What a symbol's type is, by where the symbol came from.
const Binding = union(enum) {
    scheme: types.Scheme,
    monomorphic: types.Type,
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

    fn push(self: *Scope, symbol: core.SymbolId, binding: Binding) !void {
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

pub const Globals = struct {
    context: *const anyopaque,
    lookupFn: *const fn (*const anyopaque, *Substitution, core.SymbolId) Error!?types.Scheme,

    pub fn lookup(self: Globals, subst: *Substitution, id: core.SymbolId) Error!?types.Scheme {
        return self.lookupFn(self.context, subst, id);
    }
};

pub const Inference = struct {
    gpa: Allocator,
    subst: *Substitution,
    undecided: *constraints.Set,
    globals: Globals,
    scope: Scope,
    /// Schemes generalized so far, by symbol. An earlier SCC's result.
    inferred: core.SymbolTable(types.Scheme),
    /// Declared types, written signatures, and the spelling of every symbol.
    env: *const core.env.Env,
    failure: ?Failure = null,

    pub fn init(
        gpa: Allocator,
        subst: *Substitution,
        undecided: *constraints.Set,
        globals: Globals,
        target: *const core.env.Env,
    ) Inference {
        return .{
            .gpa = gpa,
            .subst = subst,
            .undecided = undecided,
            .env = target,
            .globals = globals,
            .scope = Scope.init(gpa),
            .inferred = core.SymbolTable(types.Scheme).init(gpa),
        };
    }

    pub fn deinit(self: *Inference) void {
        self.inferred.deinit();
        self.scope.deinit();
    }

    /// The type of `term` under the current environment.
    pub fn term(self: *Inference, t: core.Term) Error!types.Type {
        return switch (t.kind) {
            .symbol => |id| try self.variable(id, t.span),
            .literal => |lit| self.literal(lit),
            .lambda => |lam| try self.lambda(lam.*),
            .apply => |app| try self.application(app.*),
            .case => |c| try self.caseOf(c.*),
            .letrec => |l| try self.letrec(l.*),
            .bind => |b| try self.streamBind(b.*),
        };
    }

    /// Instantiating a scheme also raises its constraints, on the fresh
    /// metavariables its bound variables became.
    fn instantiate(self: *Inference, scheme: types.Scheme, span: diagnostic.Span) Error!types.Type {
        const inst = try self.subst.instantiate(scheme);
        for (scheme.constraints) |c| {
            const on = try self.subst.instantiateWith(c.type, inst.metas);
            if (try self.undecided.require(self.subst, c.class, on, span)) |v| {
                return self.fail(.unsatisfied_constraint, span, .t_var, .{ .violation = v });
            }
        }
        return inst.type;
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
    /// `Gamma(x)` has four sources, in scope order:
    /// 1. a lexical binder
    /// 2. this SCC's placeholder
    /// 3. an earlier SCC's scheme
    /// 4. whatever's in `globals` (the primitive table, a synthesized scheme,
    ///    or an annotation).
    fn variable(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!types.Type {
        if (self.scope.lookup(id)) |binding| return switch (binding) {
            // Monomorphic: used at one type, not instantiated.
            .monomorphic => |t| t,
            .scheme => |s| try self.instantiate(s, span),
        };
        if (self.inferred.get(id)) |s| return try self.instantiate(s, span);
        if (try self.globals.lookup(self.subst, id)) |s| return try self.instantiate(s, span);
        return self.fail(.unresolved_name, span, .t_var, .{ .unbound = id });
    }

    /// (T-Lam)       Gamma, x : alpha |- e : tau
    ///               ------------------------------
    ///               Gamma |- \x -> e : alpha -> tau
    fn lambda(self: *Inference, lam: core.Lambda) Error!types.Type {
        const parameter = try self.subst.fresh();

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(lam.parameter, .{ .monomorphic = parameter });

        return try types.func(self.subst.arena, parameter, try self.term(lam.body));
    }

    /// (T-App)       Gamma |- e_1 : tau_1 -> tau_2
    ///               Gamma |- e_2 : tau_1
    ///               -------------------------------------------------------
    ///               Gamma |- e_1 e_2 : tau_2
    fn application(self: *Inference, app: core.Apply) Error!types.Type {
        const callee = try self.term(app.function);
        const argument = try self.term(app.argument);

        // This isn't and can never be a function. Therefore we're over applying.
        const head = self.subst.resolve(callee);
        if (head != .function and head != .meta) {
            return self.fail(
                .over_application,
                app.argument.span,
                .t_app,
                .{ .over_application = head },
            );
        }

        const result = try self.subst.fresh();
        const arrow = try types.func(self.subst.arena, argument, result);

        switch (unify.unify(self.subst, callee, arrow)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .type_mismatch,
                app.argument.span,
                .t_app,
                .{ .mismatch = m },
            ),
        }

        if (try self.undecided.recheck(self.subst)) |v| {
            return self.fail(
                .unsatisfied_constraint,
                v.origin,
                .t_app,
                .{ .violation = v },
            );
        }
        return result;
    }

    /// (T-If)        Gamma |- e_c : bool
    ///               Gamma |- e_t : tau
    ///               Gamma |- e_f : tau
    ///               --------------------------------------------
    ///               Gamma |- if e_c then e_t else e_f : tau
    fn caseOf(self: *Inference, c: core.Case) Error!types.Type {
        const scrutinee = try self.term(c.scrutinee);

        // The alternatives name their constructors statically, so the datatype
        // is known without resolving the scrutinee. Unifying against it at
        // fresh arguments is what lets `case xs of ...` fix `xs`'s type rather
        // than requiring it to be fixed already.
        const owner = core.datatypes.ownerOf(&self.env.interner, c.alternatives[0].constructor).?;
        const declared = self.env.datatypes.get(owner);

        const arguments = try self.subst.arena.alloc(types.Type, declared.parameters);
        for (arguments) |*argument| argument.* = try self.subst.fresh();
        const scrutinee_type = try types.constructed(self.subst.arena, owner, declared.name, arguments);
        try self.expect(scrutinee, scrutinee_type, c.scrutinee.span, .t_case);

        var first: ?struct { type: types.Type, span: diagnostic.Span } = null;
        for (c.alternatives, declared.constructors) |alternative, constructor| {
            const mark = self.scope.mark();
            defer self.scope.truncate(mark);

            for (alternative.binders, constructor.fields) |binder, field| {
                const at = try self.subst.instantiateWith(field, arguments);
                try self.scope.push(binder, .{ .monomorphic = at });
            }

            const body = try self.term(alternative.body);
            if (first) |f| {
                // Alternatives are checked in constructor order. Of two that
                // disagree, blame the one later in the source.
                if (alternative.body.span.start_byte >= f.span.start_byte) {
                    try self.expect(body, f.type, alternative.body.span, .t_case);
                } else {
                    try self.expect(f.type, body, f.span, .t_case);
                }
            } else {
                first = .{ .type = body, .span = alternative.body.span };
            }
        }

        return first.?.type;
    }

    /// (T-LetRec)    Gamma, x_i : alpha_i |- e_i : tau_i       (each i)
    ///               alpha_i unifies with tau_i
    ///               sigma_i = Gen(Gamma, tau_i)                (each i)
    ///               Gamma, x_i : sigma_i |- body : result
    ///               ------------------------------------------------------
    ///               Gamma |- letrec {x_i = e_i} in body : result
    fn letrec(self: *Inference, l: core.Letrec) Error!types.Type {
        const mark = self.scope.mark();
        defer self.scope.truncate(mark);

        const placeholders = try self.gpa.alloc(types.Type, l.bindings.len);
        defer self.gpa.free(placeholders);
        for (placeholders) |*p| p.* = try self.subst.fresh();

        for (l.bindings, placeholders) |b, p| {
            try self.scope.push(b.name, .{ .monomorphic = p });
        }

        // Each inferred body must unify with its placeholder.
        for (l.bindings, placeholders) |b, p| {
            const inferred = try self.term(b.value);
            try self.expect(inferred, p, b.value.span, .t_letrec);
        }

        // Generalize together, then check the body against the resulting
        // schemes rather than the placeholders.
        self.scope.truncate(mark);
        const generalized = try self.gpa.alloc(types.Scheme, l.bindings.len);
        defer self.gpa.free(generalized);
        const spans = try self.gpa.alloc(diagnostic.Span, l.bindings.len);
        defer self.gpa.free(spans);
        for (l.bindings, spans) |b, *span| span.* = b.value.span;
        try self.generalizeGroup(placeholders, spans, generalized);
        for (l.bindings, generalized) |b, scheme| {
            try self.scope.push(b.name, .{ .scheme = scheme });
        }
        return try self.term(l.body);
    }

    /// (T-Bind)      Gamma |- e_1 : [a]
    ///               Gamma, x : a |- e_2 : [b]
    ///               --------------------------------
    ///               Gamma |- bind x <- e_1 in e_2 : [b]
    fn streamBind(self: *Inference, b: core.Bind) Error!types.Type {
        const source = try self.term(b.value);
        const element = try self.subst.fresh();
        try self.expect(source, try self.subst.datatypes.list(self.subst.arena, element), b.value.span, .t_bind);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(b.name, .{ .monomorphic = element });

        const body = try self.term(b.body);
        const result = try self.subst.fresh();
        try self.expect(body, try self.subst.datatypes.list(self.subst.arena, result), b.body.span, .t_bind);
        return try self.subst.datatypes.list(self.subst.arena, result);
    }

    /// `Gen(Gamma, tau)`: quantify the metavariables free in `tau`
    /// but not in the environment, and carry the residual constraints on them
    /// into the scheme. A scheme with too many variables is reported at `span`.
    pub fn generalize(self: *Inference, t: types.Type, span: diagnostic.Span) Error!types.Scheme {
        var out: [1]types.Scheme = undefined;
        try self.generalizeGroup(&.{t}, &.{span}, &out);
        return out[0];
    }

    /// `Gen(Gamma, tau_i)` for every member of a group checked together.
    ///
    /// Each member quantifies the metavariables free in its own type but not
    /// in the environment, and carries every residual constraint that mentions
    /// one of them. A constraint shared by several members is carried by each.
    /// A member with too many variables is reported at its span.
    ///
    /// Preconditions:
    /// - `spans.len == group.len`
    /// - `out.len == group.len`
    pub fn generalizeGroup(
        self: *Inference,
        group: []const types.Type,
        spans: []const diagnostic.Span,
        out: []types.Scheme,
    ) Error!void {
        if (try self.undecided.recheck(self.subst)) |v| {
            return self.fail(.unsatisfied_constraint, v.origin, .t_letrec, .{ .violation = v });
        }

        var env: std.ArrayList(types.Meta) = .empty;
        defer env.deinit(self.gpa);
        for (self.scope.entries.items) |e| switch (e.binding) {
            .monomorphic => |m| try self.subst.freeMetas(m, &env),
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

        var taken: std.ArrayList(constraints.Constraint) = .empty;
        defer taken.deinit(self.gpa);
        try self.undecided.partitionByMetas(self.subst, quantified.items, &taken, self.gpa);

        // A scheme's constraints drop their origin span: the scheme outlives
        // the term that raised them, and a use site that violates one reports
        // at its own span instead.
        var bare: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer bare.deinit(self.gpa);
        for (group, spans, out, 0..) |t, span, *scheme, i| {
            const own = quantified.items[bounds[i]..bounds[i + 1]];
            bare.clearRetainingCapacity();
            for (taken.items) |c| {
                if (try constraints.mentionsAny(self.subst, c.type, own, self.gpa)) {
                    try bare.append(self.gpa, .{ .class = c.class, .type = c.type });
                }
            }
            scheme.* = self.subst.quantify(t, own, bare.items) catch |err| switch (err) {
                error.TooManyVariables => return self.fail(.limit, span, .t_letrec, .{
                    .too_many_variables = own.len,
                }),
                error.OutOfMemory => |e| return e,
            };
        }
    }

    /// Infers one strongly connected component of the definition graph
    /// leaving each member's generalized scheme in `inferred`.
    ///
    /// T-LetRec at top level: placeholders, bodies, unify, generalize
    /// together. Mutual recursion works because every member is in scope
    /// monomorphically while any body is checked.
    ///
    /// `desugar.Program.components` is already in dependency order, so a callee's
    /// scheme is generalized before its caller's body is inferred. The prelude
    /// arrives in earlier components than user code and needs no special case.
    pub fn component(
        self: *Inference,
        definitions: []const core.Definition,
        members: []const u32,
    ) Error!void {
        // Create a set of fresh metavars for each node
        const placeholders = try self.gpa.alloc(types.Type, members.len);
        defer self.gpa.free(placeholders);
        for (placeholders) |*p| p.* = try self.subst.fresh();

        // Each definition symbol is assigned to a monomorphic metavar
        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        for (members, placeholders) |index, p| {
            try self.scope.push(definitions[index].symbol, .{ .monomorphic = p });
        }

        // Infer each definition body to be a letrec
        for (members, placeholders) |index, p| {
            const definition = definitions[index];
            const body = try self.term(definition.body);
            try self.expect(body, p, definition.body.span, .t_letrec);
        }

        // Generalize against the environment *outside* the component, so the
        // placeholders being dropped is what lets them be quantified.
        self.scope.truncate(mark);
        const generalized = try self.gpa.alloc(types.Scheme, members.len);
        defer self.gpa.free(generalized);
        const spans = try self.gpa.alloc(diagnostic.Span, members.len);
        defer self.gpa.free(spans);
        for (members, spans) |index, *span| span.* = definitions[index].span;
        try self.generalizeGroup(placeholders, spans, generalized);

        for (members, generalized) |index, scheme| {
            const symbol = definitions[index].symbol;

            // A written signature is checked against the inferred scheme, and
            // an accepted one becomes what is exported.
            if (self.env.annotationOf(symbol)) |declared| {
                try self.checkAnnotation(scheme, declared.scheme, declared.span);
                try self.inferred.put(symbol, declared.scheme);
            } else {
                try self.inferred.put(symbol, scheme);
            }
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
    /// cover every constraint the body raises on a declared variable.
    ///
    /// An accepted annotation becomes the exported scheme.
    fn checkAnnotation(
        self: *Inference,
        inferred: types.Scheme,
        declared: types.Scheme,
        span: diagnostic.Span,
    ) Error!void {
        const before = self.subst.count();
        const rigid = try self.subst.instantiate(declared);
        const after = self.subst.count();

        const flexible = try self.subst.instantiate(inferred);

        switch (unify.unify(self.subst, rigid.type, flexible.type)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .signature_mismatch,
                span,
                .t_letrec,
                .{ .mismatch = m },
            ),
        }

        // What each declared variable resolved to. Each must still be an
        // unsolved metavariable, and no two may have become the same one.
        const representatives = try self.gpa.alloc(types.Meta, after - before);
        defer self.gpa.free(representatives);
        for (representatives, 0..) |*slot, i| {
            const id: types.Meta = @intCast(before + i);
            const resolved = self.subst.resolve(.{ .meta = id });
            const still_arbitrary = resolved == .meta and
                (resolved.meta == id or resolved.meta >= after) and
                std.mem.indexOfScalar(types.Meta, representatives[0..i], resolved.meta) == null;
            if (!still_arbitrary) {
                return self.fail(.signature_mismatch, span, .t_letrec, .{
                    .mismatch = .{
                        .reason = .incompatible,
                        .expected = declared.type,
                        .found = inferred.type,
                    },
                });
            }
            slot.* = resolved.meta;
        }

        // Each constraint the body raised, reduced to bare variables. One on a
        // declared variable must be in the declared context, and one on any
        // other variable is still owed.
        var residuals: std.ArrayList(constraints.Residual) = .empty;
        defer residuals.deinit(self.gpa);
        for (inferred.constraints) |c| {
            const on = try self.subst.instantiateWith(c.type, flexible.metas);
            residuals.clearRetainingCapacity();
            if (try constraints.reduce(self.subst, c.class, on, &residuals, self.gpa)) |culprit| {
                return self.fail(.unsatisfied_constraint, span, .t_letrec, .{ .violation = .{
                    .class = c.class,
                    .type = culprit,
                    .origin = span,
                } });
            }
            for (residuals.items) |r| {
                const index = std.mem.indexOfScalar(types.Meta, representatives, r.meta) orelse {
                    if (try self.undecided.require(self.subst, r.class, .{ .meta = r.meta }, span)) |v| {
                        return self.fail(.unsatisfied_constraint, span, .t_letrec, .{ .violation = v });
                    }
                    continue;
                };
                const on_declared = types.variable_type(@intCast(index));
                for (declared.constraints) |d| {
                    if (d.class == r.class and d.type == .variable and d.type.variable == on_declared.variable) break;
                } else return self.fail(.signature_mismatch, span, .t_letrec, .{ .violation = .{
                    .class = r.class,
                    .type = on_declared,
                    .origin = span,
                } });
            }
        }
    }

    /// `main`'s three extra checks
    pub fn checkMain(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!void {
        const scheme = self.inferred.get(id) orelse return;
        const instantiated = try self.subst.instantiate(scheme);

        // 1. `Node -> [tau]`
        const output = try self.subst.fresh();
        const wanted = try self.subst.datatypes.filter(self.subst.arena, types.node_type, output);

        switch (unify.unify(self.subst, wanted, instantiated.type)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .main_type,
                span,
                .t_letrec,
                .{ .mismatch = m },
            ),
        }

        // 2. `Serial tau`
        if (try self.undecided.require(self.subst, .Serial, output, span)) |v| {
            return self.fail(.unsatisfied_constraint, span, .t_letrec, .{ .violation = v });
        }
        if (try self.undecided.recheck(self.subst)) |v| {
            return self.fail(.unsatisfied_constraint, v.origin, .t_letrec, .{ .violation = v });
        }

        // 3. Nothing may remain undetermined
        const settled = try self.subst.resolveDeep(output);

        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.subst.freeMetas(settled, &free);

        if (free.items.len > 0 or self.undecided.all().len > 0) {
            return self.fail(.ambiguous_output, span, .t_letrec, .{
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
    }

    /// Hands the scheme table to the caller, who becomes responsible for it.
    /// `deinit` must not free it afterwards, so it is left empty.
    fn takeSchemes(self: *Inference) core.SymbolTable(types.Scheme) {
        const taken = self.inferred;
        self.inferred = core.SymbolTable(types.Scheme).init(self.gpa);
        return taken;
    }

    /// Unifies, converting a failure into a `type-mismatch` at `span`.
    fn expect(self: *Inference, found: types.Type, want: types.Type, span: diagnostic.Span, rule: Rule) Error!void {
        switch (unify.unify(self.subst, want, found)) {
            .unified => {},
            .mismatch => |m| return self.fail(
                .type_mismatch,
                span,
                rule,
                .{ .mismatch = m },
            ),
        }
    }

    fn fail(
        self: *Inference,
        category: diagnostic.Category,
        span: diagnostic.Span,
        rule: Rule,
        detail: Failure.Detail,
    ) Error {
        self.failure = .{
            .category = category,
            .span = span,
            .rule = rule,
            .detail = detail,
        };
        return error.TypeError;
    }
};

fn constructorSchemeOf(
    subst: *Substitution,
    registry: *const core.datatypes.Registry,
    interner: *const core.Interner,
    id: core.SymbolId,
) Error!?types.Scheme {
    const owner = core.datatypes.ownerOf(interner, id) orelse return null;
    const constructor = registry.constructorOf(interner, id).?;
    return try schemes.constructorScheme(subst.arena, registry.get(owner), constructor.*, owner);
}

/// Resolves a global symbol against the program: a primitive's table scheme,
/// or a synthesized symbol's constructed one.
const ProgramGlobals = struct {
    program: *const core.Program,
    /// Constructed schemes, built once per symbol.
    built: *core.SymbolTable(types.Scheme),

    fn lookup(context: *const anyopaque, subst: *Substitution, id: core.SymbolId) Error!?types.Scheme {
        const self: *const ProgramGlobals = @ptrCast(@alignCast(context));
        if (self.program.env.schemeOf(id)) |s| return s;
        if (self.built.get(id)) |s| return s;

        const scheme = switch (self.program.env.interner.details(id)) {
            .synthesized => |s| try schemes.schemeFor(subst, s),
            else => try constructorSchemeOf(
                subst,
                &self.program.env.datatypes,
                &self.program.env.interner,
                id,
            ) orelse return null,
        };
        try self.built.put(id, scheme);
        return scheme;
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

    var subst = Substitution.init(gpa, scratch.allocator(), &program.env.datatypes);
    defer subst.deinit();
    var undecided = constraints.Set.init(gpa);
    defer undecided.deinit();

    var built = core.SymbolTable(types.Scheme).init(gpa);
    defer built.deinit();
    var globals = ProgramGlobals{ .program = program, .built = &built };
    var inference = Inference.init(gpa, &subst, &undecided, .{
        .context = &globals,
        .lookupFn = ProgramGlobals.lookup,
    }, &program.env);
    defer inference.deinit();

    inference.check(program) catch |err| switch (err) {
        error.TypeError => {
            const failure = inference.failure.?;

            var buf: std.Io.Writer.Allocating = .init(sink.allocator);
            defer buf.deinit();

            var names: types.MetaNames = .{};
            switch (failure.detail) {
                .mismatch => |m| try buf.writer.print("Expected `{f}`, found `{f}`.", .{
                    (try subst.resolveDeep(m.expected)).named(&names),
                    (try subst.resolveDeep(m.found)).named(&names),
                }),
                .violation => |v| try v.format(&buf.writer),
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
            }

            try sink.report(failure.category, failure.span, "{s}", .{buf.written()});
            return error.TypeCheckFailed;
        },
        error.TooManyRecordFields => {
            try sink.report(
                .type_mismatch,
                diagnostic.Span.unknown,
                "a record has more fields than the type system can index",
                .{},
            );
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

const testing = std.testing;

/// Drives inference without a `desugar.Program`: a symbol table of schemes and
/// hand-built Core terms. The engine path arrives at step 6.
const Fixture = struct {
    env: core.env.Env,
    subst: Substitution,
    undecided: constraints.Set,
    builder: core.Builder,
    inference: Inference,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try core.env.Env.init(gpa),
            .subst = undefined,
            .undecided = constraints.Set.init(gpa),
            .builder = undefined,
            .inference = undefined,
        };
        try self.env.datatypes.declareStructural(&self.env.interner, self.env.allocator());
        self.subst = Substitution.init(gpa, self.env.allocator(), &self.env.datatypes);
        self.builder = .{ .allocator = self.env.allocator() };
        try self.declareFlag();
        self.inference = Inference.init(
            gpa,
            &self.subst,
            &self.undecided,
            .{
                .context = self,
                .lookupFn = lookupScheme,
            },
            &self.env,
        );
        return self;
    }

    /// The global sources, minus annotations: the hand-built
    /// scheme table standing in for primitives, then synthesized symbols built
    /// on demand.
    fn lookupScheme(
        context: *const anyopaque,
        subst: *Substitution,
        id: core.SymbolId,
    ) Error!?types.Scheme {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (self.env.schemeOf(id)) |s| return s;
        switch (self.env.interner.details(id)) {
            .synthesized => |s| return try schemes.schemeFor(subst, s),
            else => {},
        }
        return try constructorSchemeOf(subst, &self.env.datatypes, &self.env.interner, id);
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.inference.deinit();
        self.undecided.deinit();
        self.subst.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    fn define(self: *Fixture, spelling: []const u8, scheme: types.Scheme) !core.SymbolId {
        const id = try self.env.interner.intern(spelling, .vanilla);
        try self.env.setScheme(id, scheme);
        return id;
    }

    fn name(self: *Fixture, spelling: []const u8) !core.SymbolId {
        return self.env.interner.lookup(spelling) orelse
            try self.env.interner.intern(spelling, .vanilla);
    }

    /// Interns a synthesized symbol under its bracketed spelling, the way the
    /// desugarer does, and records what it was generated from.
    fn synthesize(self: *Fixture, spelling: []const u8, what: core.Synthesized) !core.SymbolId {
        return try self.env.interner.internOrGet(spelling, .{ .synthesized = what });
    }

    fn sym(self: *Fixture, id: core.SymbolId) core.Term {
        _ = self;
        return .{ .kind = .{ .symbol = id }, .span = diagnostic.Span.unknown };
    }

    fn lit(self: *Fixture, l: core.Literal) core.Term {
        _ = self;
        return .{ .kind = .{ .literal = l }, .span = diagnostic.Span.unknown };
    }

    fn regexLit(self: *Fixture, pattern: []const u8) core.Term {
        return self.lit(.{ .regex = pattern });
    }

    fn app(self: *Fixture, function: core.Term, argument: core.Term) !core.Term {
        return self.builder.apply(function, argument, diagnostic.Span.unknown);
    }

    fn lam(self: *Fixture, parameter: core.SymbolId, body: core.Term) !core.Term {
        return self.builder.lambda(parameter, body, diagnostic.Span.unknown);
    }

    fn declareFlag(self: *Fixture) !void {
        const arena = self.env.allocator();
        const constructors = try arena.dupe(core.datatypes.Constructor, &.{
            .{ .symbol = try self.env.interner.intern("Off", .vanilla), .tag = 0, .fields = &.{} },
            .{ .symbol = try self.env.interner.intern("On", .vanilla), .tag = 1, .fields = &.{} },
        });
        _ = try self.env.datatypes.declare(&self.env.interner, "Flag", 0, constructors, .{});
    }

    /// `case c of { Off -> e; On -> t }`, alternatives in tag order.
    fn cond(self: *Fixture, c: core.Term, t: core.Term, e: core.Term) !core.Term {
        const alternatives = try self.builder.slice(core.Case.Alternative, 2);
        alternatives[0] = .{
            .constructor = self.env.interner.lookup("Off").?,
            .binders = &.{},
            .body = e,
        };
        alternatives[1] = .{
            .constructor = self.env.interner.lookup("On").?,
            .binders = &.{},
            .body = t,
        };
        return self.builder.case(c, alternatives, diagnostic.Span.unknown);
    }

    /// A nullary constructor reference.
    fn con(self: *Fixture, spelling: []const u8) core.Term {
        return self.builder.symbol(self.env.interner.lookup(spelling).?, diagnostic.Span.unknown);
    }

    fn rec(self: *Fixture, bindings: []const core.Letrec.Binding, body: core.Term) !core.Term {
        return self.builder.letrec(bindings, body, diagnostic.Span.unknown);
    }

    fn streamBind(
        self: *Fixture,
        n: core.SymbolId,
        value: core.Term,
        body: core.Term,
    ) !core.Term {
        return self.builder.bind(n, value, body, diagnostic.Span.unknown);
    }

    fn expectType(self: *Fixture, t: core.Term, expected: []const u8) !void {
        const inferred = try self.inference.term(t);
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try (try self.subst.resolveDeep(inferred)).format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    fn expectScheme(self: *Fixture, id: core.SymbolId, expected: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try self.inference.schemeOf(id).?.format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }

    fn expectFails(self: *Fixture, t: core.Term, category: diagnostic.Category) !void {
        try testing.expectError(error.TypeError, self.inference.term(t));
        try testing.expectEqual(category, self.inference.failure.?.category);
    }
};

test "a literal has its scalar type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectType(fix.lit(.{ .number = 1 }), "Int");
    try fix.expectType(fix.lit(.{ .string = "s" }), "String");
    try fix.expectType(fix.regexLit("r"), "Regex");
}

test "a symbol's scheme is instantiated at its use" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const identity = try fix.define("identity", .{
        .quantified = 1,
        .type = try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(0)),
    });
    try fix.expectType(fix.sym(identity), "?0 -> [?0]");
}

test "two uses of one polymorphic symbol are independent" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const identity = try fix.define("identity", .{
        .quantified = 1,
        .type = comptime types.func_type(types.variable_type(0), types.variable_type(0)),
    });

    // `identity 1` must not fix the *other* use to `int`.
    try fix.expectType(try fix.app(fix.sym(identity), fix.lit(.{ .number = 1 })), "Int");
    try fix.expectType(fix.sym(identity), "?2 -> ?2");
}

test "an unbound symbol is an unresolved name" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const missing = try fix.name("nope");
    try fix.expectFails(fix.sym(missing), .unresolved_name);
}

test "a lambda's parameter is monomorphic in its body" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const x = try fix.name("x");
    try fix.expectType(try fix.lam(x, fix.sym(x)), "?0 -> ?0");
}

test "application unifies the argument with the parameter" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    try fix.expectType(try fix.app(fix.sym(inc), fix.lit(.{ .number = 1 })), "Int");
}

test "an argument of the wrong type is a type mismatch" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    // `errors/types/001`: `double "text"`.
    try fix.expectFails(try fix.app(fix.sym(inc), fix.lit(.{ .string = "text" })), .type_mismatch);
    try testing.expectEqual(Rule.t_app, fix.inference.failure.?.rule);
}

test "applying a saturated function is over-application, not a mismatch" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/011`: `inc 1 2` where `inc : Int -> Int`. The callee
    // resolved to a non-arrow, so there is nothing left to apply.
    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    const once = try fix.app(fix.sym(inc), fix.lit(.{ .number = 1 }));
    const twice = try fix.app(once, fix.lit(.{ .number = 2 }));

    try fix.expectFails(twice, .over_application);
    try testing.expect(fix.inference.failure.?.detail == .over_application);
}

test "applying a non-function is over-application" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/012`: `n 1` where `n : int`.
    const n = try fix.define("n", .{ .type = types.int_type });
    try fix.expectFails(try fix.app(fix.sym(n), fix.lit(.{ .number = 1 })), .over_application);
}

test "an unresolved callee unifies rather than failing" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // A callee that is still a metavariable is neither error. Applying
    // it is what *determines* that it is a function.
    const x = try fix.name("x");
    const body = try fix.app(fix.sym(x), fix.lit(.{ .number = 1 }));
    try fix.expectType(try fix.lam(x, body), "(Int -> ?1) -> ?1");
}

test "a case unifies its alternatives" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.con("On"),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectType(c, "Int");
}

test "a scrutinee that is not a declared type is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectFails(c, .type_mismatch);
    try testing.expectEqual(Rule.t_case, fix.inference.failure.?.rule);
}

test "alternatives of different types are rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const c = try fix.cond(
        fix.con("On"),
        fix.lit(.{ .number = 1 }),
        fix.lit(.{ .string = "s" }),
    );
    try fix.expectFails(c, .type_mismatch);
}

test "a letrec group generalizes and each use instantiates" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // letrec { id = \x -> x } in id
    const x = try fix.name("x");
    const id = try fix.name("id");
    const bindings = try fix.builder.slice(core.Letrec.Binding, 1);
    bindings[0] = .{ .name = id, .value = try fix.lam(x, fix.sym(x)) };

    try fix.expectType(try fix.rec(bindings, fix.sym(id)), "?2 -> ?2");
}

test "a letrec member is monomorphic while the group is checked" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // letrec { loop = \x -> loop x } in loop. The recursive use must not be
    // generalized mid-check, or the placeholder would never be constrained.
    const x = try fix.name("x");
    const loop = try fix.name("loop");
    const recursive = try fix.app(fix.sym(loop), fix.sym(x));
    const bindings = try fix.builder.slice(core.Letrec.Binding, 1);
    bindings[0] = .{ .name = loop, .value = try fix.lam(x, recursive) };

    try fix.expectType(try fix.rec(bindings, fix.sym(loop)), "?3 -> ?4");
}

test "a stream bind takes a list and yields a list" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // bind c <- children_of in pure_of c
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const pure_of = try fix.define("pure_of", .{
        .quantified = 1,
        .type = try types.func(
            fix.subst.arena,
            types.variable_type(0),
            try fix.subst.datatypes.list(fix.subst.arena, types.variable_type(0)),
        ),
    });

    const c = try fix.name("c");
    const body = try fix.app(fix.sym(pure_of), fix.sym(c));
    try fix.expectType(try fix.streamBind(c, fix.sym(children), body), "[Node]");
}

test "a stream bind over a non-list is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const n = try fix.define("n", .{ .type = types.int_type });
    const c = try fix.name("c");
    try fix.expectFails(try fix.streamBind(c, fix.sym(n), fix.sym(c)), .type_mismatch);
    try testing.expectEqual(Rule.t_bind, fix.inference.failure.?.rule);
}

test "a bind body that is not a list is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // The body must produce `[b]`; a bare element is not one.
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const c = try fix.name("c");
    try fix.expectFails(try fix.streamBind(c, fix.sym(children), fix.sym(c)), .type_mismatch);
}

test "a bound name is monomorphic in the bind body" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/output/013`: `c` cannot be used at two types. Here
    // the second use forces `node` against `[?]`, which cannot hold.
    const children = try fix.define("children_of", .{
        .type = try fix.subst.datatypes.list(fix.subst.arena, types.node_type),
    });
    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    const c = try fix.name("c");
    const sized_use = try fix.app(fix.sym(length_of), fix.sym(c));
    const b = try fix.streamBind(c, fix.sym(children), sized_use);

    // `Sized node` is refuted, and the constraint was raised at the use site.
    try fix.expectFails(b, .unsatisfied_constraint);
}

test "instantiating a constrained scheme raises the constraint at the use" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    // `Sized int` is refuted.
    const applied = try fix.app(fix.sym(length_of), fix.lit(.{ .number = 1 }));
    try fix.expectFails(applied, .unsatisfied_constraint);
}

test "a constraint on an open type defers rather than rejecting" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    // `\x -> length_of x`: `x`'s type is open, so `Sized` cannot be decided
    // yet and must not reject.
    const x = try fix.name("x");
    const body = try fix.app(fix.sym(length_of), fix.sym(x));
    try fix.expectType(try fix.lam(x, body), "?0 -> Int");
    try testing.expectEqual(1, fix.undecided.all().len);
}

test "generalization quantifies what the environment does not hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const x = try fix.name("x");
    const inferred = try fix.inference.term(try fix.lam(x, fix.sym(x)));

    const scheme = try fix.inference.generalize(inferred, diagnostic.Span.unknown);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try testing.expectEqualStrings("a -> a", buf.written());
    try testing.expectEqual(1, scheme.quantified);
}

test "generalization does not quantify a metavariable the scope still holds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Inside `\x -> ...`, `x`'s type is monomorphic and must not be
    // quantified by a generalization in the body.
    const outer = try fix.subst.fresh();
    try fix.inference.scope.push(try fix.name("x"), .{ .monomorphic = outer });

    const scheme = try fix.inference.generalize(outer, diagnostic.Span.unknown);
    try testing.expectEqual(0, scheme.quantified);
}

test "generalization carries the residual constraint into the scheme" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const length_of = try fix.define("length_of", .{
        .quantified = 1,
        .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
        .type = comptime types.func_type(types.variable_type(0), types.int_type),
    });

    const x = try fix.name("x");
    const body = try fix.app(fix.sym(length_of), fix.sym(x));
    const inferred = try fix.inference.term(try fix.lam(x, body));

    const scheme = try fix.inference.generalize(inferred, diagnostic.Span.unknown);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    // The deferred `Sized` follows the variable it constrains.
    try testing.expectEqualStrings("Sized a => a -> Int", buf.written());
}

test "a component's scheme is generalized and visible to later components" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  use = id
    const x = try fix.name("x");
    const id = try fix.name("id");
    const use = try fix.name("use");

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = use, .body = fix.sym(id), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });

    try fix.expectScheme(id, "a -> a");
    // `use` instantiated `id`'s scheme, then generalized its own.
    try fix.expectScheme(use, "a -> a");
}

test "mutually recursive definitions are one component, generalized together" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // even = \n -> odd n;  odd = \n -> even n
    const n = try fix.name("n");
    const even = try fix.name("even");
    const odd = try fix.name("odd");

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = even, .body = try fix.lam(n, try fix.app(fix.sym(odd), fix.sym(n))), .span = .unknown };
    definitions[1] = .{ .symbol = odd, .body = try fix.lam(n, try fix.app(fix.sym(even), fix.sym(n))), .span = .unknown };

    // Both in one component: each references the other, so neither can be
    // generalized before the other is checked.
    try fix.inference.program(definitions, &.{&.{ 0, 1 }});

    try fix.expectScheme(even, "a -> b");
    try fix.expectScheme(odd, "a -> b");
}

test "a definition is checked against its callee's generalized scheme" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  pair = \y -> id (id y)
    // Two uses of `id` at the same type here, but through *separate*
    // instantiations, which only works if `id` was generalized first.
    const x = try fix.name("x");
    const y = try fix.name("y");
    const id = try fix.name("id");
    const pair = try fix.name("pair");

    const inner = try fix.app(fix.sym(id), fix.sym(y));
    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = pair, .body = try fix.lam(y, try fix.app(fix.sym(id), inner)), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });
    try fix.expectScheme(pair, "a -> a");
}

test "a polymorphic callee is used at two different types" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // id = \x -> x;  both = \f -> f (id 1) (id "s")
    // The payoff of generalization: one definition, two instantiations.
    const x = try fix.name("x");
    const g = try fix.name("g");
    const id = try fix.name("id");
    const both = try fix.name("both");

    const at_int = try fix.app(fix.sym(id), fix.lit(.{ .number = 1 }));
    const at_string = try fix.app(fix.sym(id), fix.lit(.{ .string = "s" }));
    const applied = try fix.app(try fix.app(fix.sym(g), at_int), at_string);

    const definitions = try fix.builder.slice(core.Definition, 2);
    definitions[0] = .{ .symbol = id, .body = try fix.lam(x, fix.sym(x)), .span = .unknown };
    definitions[1] = .{ .symbol = both, .body = try fix.lam(g, applied), .span = .unknown };

    try fix.inference.program(definitions, &.{ &.{0}, &.{1} });
    try fix.expectScheme(both, "(Int -> String -> a) -> a");
}

test "a component member that does not typecheck fails the walk" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const inc = try fix.define("inc", .{
        .type = comptime types.func_type(types.int_type, types.int_type),
    });
    const bad = try fix.name("bad");

    const definitions = try fix.builder.slice(core.Definition, 1);
    definitions[0] = .{
        .symbol = bad,
        .body = try fix.app(fix.sym(inc), fix.lit(.{ .string = "s" })),
        .span = .unknown,
    };

    try testing.expectError(
        error.TypeError,
        fix.inference.program(definitions, &.{&.{0}}),
    );
    try testing.expectEqual(diagnostic.Category.type_mismatch, fix.inference.failure.?.category);
}

test "a recursive definition stays monomorphic within its own component" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // loop = \x -> loop x. The self-reference must see the placeholder, not
    // a scheme, or the recursion would generalize before it is constrained.
    const x = try fix.name("x");
    const loop = try fix.name("loop");

    const definitions = try fix.builder.slice(core.Definition, 1);
    definitions[0] = .{
        .symbol = loop,
        .body = try fix.lam(x, try fix.app(fix.sym(loop), fix.sym(x))),
        .span = .unknown,
    };

    try fix.inference.program(definitions, &.{&.{0}});
    try fix.expectScheme(loop, "a -> b");
}

test "a kind literal is a Kind" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectType(fix.lit(.{ .kind = .{ .name = "class_declaration", .id = 42 } }), "Kind");
}

test "a synthesized operator takes scalars, not filters" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `op[=] : Eq a => a -> a -> Bool`. Applying it to two ints is fine.
    const eq = try fix.synthesize("op[=]", .{ .operator = .eq });
    const applied = try fix.app(
        try fix.app(fix.sym(eq), fix.lit(.{ .number = 1 })),
        fix.lit(.{ .number = 2 }),
    );
    try fix.expectType(applied, "Bool");
}

test "an operator's constraint is refuted on a regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/015`: `r"a" = r"a"` fails `Eq regex`.
    const eq = try fix.synthesize("op[=]", .{ .operator = .eq });
    const applied = try fix.app(
        try fix.app(fix.sym(eq), fix.regexLit("a")),
        fix.regexLit("a"),
    );
    try fix.expectFails(applied, .unsatisfied_constraint);
}

test "ordering two nodes is refuted while comparing them is not" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `errors/types/019`'s point: `node` has `Eq` but not `Ord`.
    const node_of = try fix.define("node_of", .{ .type = types.node_type });
    const lt = try fix.synthesize("op[<]", .{ .operator = .lt });
    const ordered = try fix.app(
        try fix.app(fix.sym(lt), fix.sym(node_of)),
        fix.sym(node_of),
    );
    try fix.expectFails(ordered, .unsatisfied_constraint);
}

test "a record applied to two field values yields a record" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `{ k = kind n, n = 1 }` after desugaring.
    const record = try fix.synthesize(
        "record[k,n]",
        .{ .record = &.{ "k", "n" } },
    );
    const a_string = try fix.define("a_string", .{ .type = types.string_type });
    const an_int = try fix.define("an_int", .{ .type = types.int_type });

    const applied = try fix.app(
        try fix.app(fix.sym(record), fix.sym(a_string)),
        fix.sym(an_int),
    );
    try fix.expectType(applied, "{k: String, n: Int}");
}

test "record fields are independent" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // Each field quantifies its own variable, so fields of unrelated types sit
    // beside each other. Under the filter-typed record they shared an input
    // and this was a mismatch.
    const record = try fix.synthesize(
        "record[a,b]",
        .{ .record = &.{ "a", "b" } },
    );
    const a_node = try fix.define("a_node", .{ .type = types.node_type });
    const a_regex = try fix.define("a_regex", .{ .type = types.regex_type });

    const applied = try fix.app(
        try fix.app(fix.sym(record), fix.sym(a_node)),
        fix.sym(a_regex),
    );
    try fix.expectType(applied, "{a: Node, b: Regex}");
}

test "a synthesized field access composes with a kind test" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `children | of_kind :class_declaration | .name`, the navigation chain
    // every fixture opens with, as Core composition.
    const compose = try fix.define("compose", .{
        .quantified = 3,
        .type = try types.func(
            fix.subst.arena,
            try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(1)),
            try types.func(
                fix.subst.arena,
                try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(1), types.variable_type(2)),
                try fix.subst.datatypes.filter(fix.subst.arena, types.variable_type(0), types.variable_type(2)),
            ),
        ),
    });
    const children = try fix.define("children", .{
        .type = try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.node_type),
    });
    const of_kind = try fix.define("of_kind", .{
        .type = try types.func(
            fix.subst.arena,
            types.kind_type,
            try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.node_type),
        ),
    });
    const class_declaration = try fix.app(
        fix.sym(of_kind),
        fix.lit(.{ .kind = .{ .name = "class_declaration", .id = 1 } }),
    );
    const field = try fix.synthesize("field[name]", .{ .field = .{ .name = "name", .id = 2 } });

    const first = try fix.app(try fix.app(fix.sym(compose), fix.sym(children)), class_declaration);
    const chain = try fix.app(try fix.app(fix.sym(compose), first), fix.sym(field));
    try fix.expectType(chain, "Node -> [Node]");
}
