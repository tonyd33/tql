//! Algorithm W over Core, with a mutable substitution.

const std = @import("std");
const constraints = @import("constraints.zig");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
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

pub const Error = error{TypeError} || Allocator.Error;

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
    /// Declared types, written signatures, and the spelling of every symbol.
    env: *const core.env.Env,
    failure: ?Failure = null,

    pub fn init(
        gpa: Allocator,
        subst: *Substitution,
        undecided: *constraints.Set,
        target: *const core.env.Env,
    ) Inference {
        return .{
            .gpa = gpa,
            .subst = subst,
            .undecided = undecided,
            .env = target,
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
    /// 4. the environment's scheme for a primitive, a synthesized symbol or a
    ///    constructor
    fn variable(self: *Inference, id: core.SymbolId, span: diagnostic.Span) Error!types.Type {
        if (self.scope.lookup(id)) |binding| return switch (binding) {
            // Monomorphic: used at one type, not instantiated.
            .monomorphic => |t| t,
            .scheme => |s| try self.instantiate(s, span),
        };
        if (self.inferred.get(id)) |s| return try self.instantiate(s, span);
        if (self.env.schemeOf(id)) |s| return try self.instantiate(s, span);
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
        const expanded = self.subst.expand(head);
        if (expanded != .function and expanded != .meta) {
            return self.fail(
                .over_application,
                app.argument.span,
                .t_app,
                .{ .over_application = head },
            );
        }

        const result = try self.subst.fresh();
        const arrow = try types.func(self.subst.arena, argument, result);

        switch (try unify.unify(self.subst, callee, arrow)) {
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

        const generalized = try self.gpa.alloc(types.Scheme, l.bindings.len);
        defer self.gpa.free(generalized);
        const spans = try self.gpa.alloc(diagnostic.Span, l.bindings.len);
        defer self.gpa.free(spans);
        for (l.bindings, spans) |b, *span| span.* = b.value.span;
        try self.inferGroup(l.bindings, spans, generalized);

        // Check the body against the generalized schemes.
        for (l.bindings, generalized) |b, scheme| {
            try self.scope.push(b.name, .{ .scheme = scheme });
        }
        return try self.term(l.body);
    }

    /// Infer a group of mutually recursive bindings and generalize them
    /// together, writing each one's scheme to `out`. Generalization reports
    /// against `spans`, one per binding.
    fn inferGroup(
        self: *Inference,
        bindings: []const core.Letrec.Binding,
        spans: []const diagnostic.Span,
        out: []types.Scheme,
    ) Error!void {
        const placeholders = try self.gpa.alloc(types.Type, bindings.len);
        defer self.gpa.free(placeholders);
        for (placeholders) |*p| p.* = try self.subst.fresh();

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        for (bindings, placeholders) |b, p| {
            try self.scope.push(b.name, .{ .monomorphic = p });
        }

        // Each inferred body must unify with its placeholder.
        for (bindings, placeholders) |b, p| {
            const inferred = try self.term(b.value);
            try self.expect(inferred, p, b.value.span, .t_letrec);
        }

        // Generalize against the environment *outside* the group, so the
        // placeholders being dropped is what lets them be quantified.
        self.scope.truncate(mark);
        try self.generalizeGroup(placeholders, spans, out);
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
        const generalized = try self.gpa.alloc(types.Scheme, members.len);
        defer self.gpa.free(generalized);
        try self.inferGroup(bindings, spans, generalized);

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

        switch (try unify.unify(self.subst, rigid.type, flexible.type)) {
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
            const resolved = self.subst.expand(.{ .meta = id });
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

        switch (try unify.unify(self.subst, wanted, instantiated.type)) {
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
        switch (try unify.unify(self.subst, want, found)) {
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

    var inference = Inference.init(gpa, &subst, &undecided, &program.env);
    defer inference.deinit();

    inference.check(program) catch |err| switch (err) {
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
