//! Bidirectional inference over Core, with a mutable substitution.
//! Inference elaborates: each term is rebuilt with dictionary passing made
//! explicit.

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
        /// A constraint on a signature's variables its context does not
        /// give.
        not_given: struct {
            needed: types.TypeClassConstraint,
            binder: core.SymbolId,
        },
        over_application: types.Type,
        not_a_function: types.Type,
        view_not_function: types.Type,
        unbound: core.SymbolId,
        too_many_variables: usize,
        ambiguous: types.TypeClassConstraint,
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
    /// The value each recursive group of several top-level definitions with
    /// dictionaries selects its members from.
    shared: std.ArrayList(core.Definition) = .empty,
    /// Each instance's dictionary, as `finish` builds it.
    instances: std.ArrayList(evidence.Instance) = .empty,

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
        self.shared.deinit(self.gpa);
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

    /// Infers `t`'s type, or checks `t` against `expected` when it is
    /// given. A checked term reports a mismatch at the subterm that
    /// disagrees, and its type is `expected`. See Checking in
    /// type_check.zig.
    pub fn elaborate(self: *Inference, t: core.Term, expected: ?types.Type) Error!Elaborated {
        return switch (t.kind) {
            .symbol => |id| try self.subsume(try self.variable(id, t.span), expected, t.span),
            .literal => |lit| try self.subsume(.{ .type = self.literal(lit), .term = t }, expected, t.span),
            .lambda => |lam| try self.lambda(lam.*, t, expected),
            .apply => try self.application(t, expected),
            .case => |c| try self.caseOf(c.*, t, expected),
            .let => |l| try self.let(l.*, t, expected),
            .letrec => |l| try self.letrec(l.*, t, expected),
        };
    }

    /// (T-Sub)   `inferred` checked against `expected`, reported at `span`.
    fn subsume(self: *Inference, inferred: Elaborated, expected: ?types.Type, span: diagnostic.Span) Error!Elaborated {
        if (expected) |want| try self.expect(inferred.type, want, span);
        return inferred;
    }

    const Instantiated = struct {
        type: types.Type,
        /// One evidence variable per constraint, in the scheme's order.
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
            try variables.append(self.builder.allocator, self.builder.symbol(symbol, span));
        }
        return .{ .type = inst.type, .evidence = variables.items };
    }

    /// Raises `class t` as a wanted of frame `at`. Returns its fresh
    /// evidence variable.
    fn raise(self: *Inference, at: u32, class: classes.ClassId, t: types.Type, origin: diagnostic.Span) Error!core.SymbolId {
        const symbol = try self.env.interner.fresh("evidence");
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
    /// dictionary parameters, one per constraint, in order.
    fn parameters(self: *Inference, frame: u32, context: []const types.TypeClassConstraint) Error![]const core.SymbolId {
        const bound = try self.builder.slice(core.SymbolId, context.len);
        for (context, bound) |c, *parameter| {
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

    /// A new implication, a child of the current frame, at the current
    /// level. Its body is elaborated by `elaborateIn` before the level is
    /// left.
    fn implication(self: *Inference) Error!u32 {
        return try self.evidence.frame(self.frame, self.subst.level);
    }

    /// Elaborates `t` against `expected` in frame `at`.
    fn elaborateIn(self: *Inference, at: u32, t: core.Term, expected: ?types.Type) Error!Elaborated {
        const enclosing = self.frame;
        defer self.frame = enclosing;
        self.frame = at;
        return try self.elaborate(t, expected);
    }

    /// Whether `t` reads a variable bound by an enclosing lambda, `case`
    /// alternative or join point, or by a binding that was not generalized.
    fn mentionsMonomorphic(self: *Inference, t: core.Term) bool {
        return core.free.anyMention(t, self, isMonomorphicUse) catch |err| switch (err) {};
    }

    fn isMonomorphicUse(self: *Inference, symbol: core.SymbolId, role: core.free.Role) error{}!bool {
        if (role != .use) return false;
        const binding = self.scope.lookup(symbol) orelse return false;
        return binding == .monomorphic;
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

    /// (T-Abs<=)     Gamma, x : tau_1 |- e <= tau_2
    ///               ------------------------------
    ///               Gamma |- \x -> e <= tau_1 -> tau_2
    ///
    /// (T-Abs=>)     Gamma, x : alpha |- e => tau
    ///               ------------------------------
    ///               Gamma |- \x -> e => alpha -> tau
    ///
    /// A lambda checked against a metavariable first makes it an arrow of
    /// fresh metavariables. Against any other type that is not an arrow, the
    /// lambda is inferred and the two types compared.
    fn lambda(self: *Inference, lam: core.Lambda, t: core.Term, expected: ?types.Type) Error!Elaborated {
        var parameter: types.Type = undefined;
        var result: ?types.Type = null;
        if (expected) |want| switch (self.subst.expand(want)) {
            .function => |arrow| {
                parameter = arrow.from;
                result = arrow.to;
            },
            .meta => {
                parameter = try self.subst.fresh(.type);
                result = try self.subst.fresh(.type);
                try self.expect(try types.func(self.subst.arena, parameter, result.?), want, t.span);
            },
            else => return try self.subsume(try self.lambda(lam, t, null), want, t.span),
        } else parameter = try self.subst.fresh(.type);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(lam.parameter, .{ .monomorphic = parameter });

        const body = try self.elaborate(lam.body, result);
        return .{
            .type = expected orelse try types.func(self.subst.arena, parameter, body.type),
            .term = if (core.same(body.term, lam.body)) t else try self.builder.lambda(lam.parameter, body.term, t.span),
        };
    }

    /// (T-App)       Gamma |- e_1 => tau_1      alpha, beta fresh
    ///               tau_1 ~ alpha -> beta      Gamma |- e_2 <= alpha
    ///               -------------------------------------------------
    ///               Gamma |- e_1 e_2 => beta
    ///
    /// (T-App<=)     Gamma |- f => tau_0      alpha_1 .. alpha_n fresh
    ///               tau_0 ~ alpha_1 -> .. -> alpha_n -> tau
    ///               Gamma |- e_i <= alpha_i
    ///               -------------------------------------------------
    ///               Gamma |- f e_1 .. e_n <= tau
    ///
    /// Both run over a whole spine `f e_1 .. e_n`: `f` is inferred and its
    /// type split into `n` parameters and a result. A checked application
    /// compares the result with what is expected before checking the
    /// arguments against the parameters, so an argument is checked against
    /// a parameter the context has already fixed.
    fn application(self: *Inference, t: core.Term, expected: ?types.Type) Error!Elaborated {
        const nodes = try self.gpa.alloc(core.Term, t.spineLength());
        defer self.gpa.free(nodes);
        t.applications(nodes);
        const froms = try self.gpa.alloc(types.Type, nodes.len);
        defer self.gpa.free(froms);

        const head_term = nodes[0].kind.apply.function;
        const head = try self.elaborate(head_term, null);
        // The arguments the callee's type takes, up to the first it cannot.
        var callee = head.type;
        const taken = for (nodes, froms, 0..) |node, *parameter, i| {
            switch (self.subst.expand(callee)) {
                .function => |arrow| {
                    parameter.* = arrow.from;
                    callee = arrow.to;
                    continue;
                },
                else => {},
            }
            parameter.* = try self.subst.fresh(.type);
            const result = try self.subst.fresh(.type);
            const arrow = try types.func(self.subst.arena, parameter.*, result);
            switch (try unify.unify(self.subst, callee, arrow)) {
                .unified => callee = result,
                .mismatch => {
                    try self.notAFunction(node.kind.apply.*, callee, arrow);
                    break i;
                },
            }
        } else nodes.len;

        // An application its callee cannot take has a made-up type.
        const result = if (taken < nodes.len) blk: {
            const made_up = expected orelse try self.poisoned();
            self.subst.poison(made_up);
            break :blk made_up;
        } else blk: {
            if (expected) |want| try self.expect(callee, want, t.span);
            break :blk expected orelse callee;
        };
        var function = head.term;
        for (nodes, 0..) |node, i| {
            const app = node.kind.apply.*;
            const argument = try self.elaborate(app.argument, if (i < taken) froms[i] else null);
            if (core.same(function, app.function) and core.same(argument.term, app.argument)) {
                function = node;
                continue;
            }
            var rebuilt = app;
            rebuilt.function = function;
            rebuilt.argument = argument.term;
            function = try self.builder.application(rebuilt, node.span);
        }
        return .{ .type = result, .term = function };
    }

    /// Reports `app`'s function, of type `callee`, as one that cannot take
    /// its argument, `callee` having failed to unify with `arrow`.
    fn notAFunction(self: *Inference, app: core.Apply, callee: types.Type, arrow: types.Type) Error!void {
        if (app.view) return try self.reportAbout(
            .type_mismatch,
            app.function.span,
            .{ .view_not_function = self.subst.resolve(callee) },
            &.{ callee, arrow },
        );
        if (app.function.kind != .apply) return try self.reportAbout(
            .type_mismatch,
            app.function.span,
            .{ .not_a_function = self.subst.resolve(callee) },
            &.{ callee, arrow },
        );
        // This isn't and can never be a function. Therefore we're over
        // applying.
        try self.reportAbout(
            .over_application,
            app.argument.span,
            .{ .over_application = self.subst.resolve(callee) },
            &.{ callee, arrow },
        );
    }

    /// (T-Case)      Gamma |- e : T tau_1 .. tau_m
    ///               C_i : sigma_i_1 -> .. -> sigma_i_k -> T a_1 .. a_m
    ///               Gamma, b : T tau_1 .. tau_m, xs_i : [a := tau] sigma_i |- e_i <= tau
    ///               Gamma, b : T tau_1 .. tau_m |- e_0 <= tau
    ///               ------------------------------------------------------------
    ///               Gamma |- case e of b { C_i xs_i -> e_i; _ -> e_0 } <= tau
    ///
    /// An inferred `case` is checked against a fresh metavariable. Branches
    /// are checked in source order, so of two that disagree the later one is
    /// blamed.
    fn caseOf(self: *Inference, c: core.Case, t: core.Term, expected: ?types.Type) Error!Elaborated {
        const result = expected orelse try self.subst.fresh(.type);

        // The alternatives name their constructors statically, so the datatype
        // is known without inferring the scrutinee, and the scrutinee is
        // checked against it at fresh arguments. A `case` with only a default
        // leaves the scrutinee's type free.
        var arguments: []types.Type = &.{};
        var scrutinee_type: ?types.Type = null;
        if (c.alternatives.len > 0) {
            const owner = core.datatypes.ownerOf(&self.env.interner, c.alternatives[0].constructor).?;
            const declared = self.env.datatypes.get(owner);
            arguments = try self.subst.arena.alloc(types.Type, declared.parameters.len);
            for (arguments, declared.parameters) |*argument, kind| argument.* = try self.subst.fresh(kind);
            scrutinee_type = try types.constructed(self.subst.arena, owner, declared.name, arguments);
        }
        const elaborated_scrutinee = try self.elaborate(c.scrutinee, scrutinee_type);
        const scrutinee = elaborated_scrutinee.type;

        const outer = self.scope.mark();
        defer self.scope.truncate(outer);
        if (c.binder) |binder| try self.scope.push(binder, .{ .monomorphic = scrutinee });

        // Each alternative's index, and the default's as `c.alternatives.len`,
        // in source order.
        const order = try self.gpa.alloc(usize, c.alternatives.len + @intFromBool(c.default != null));
        defer self.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        std.mem.sort(usize, order, c, inBranchOrder);

        var alternatives: core.Rebuilt(core.Case.Alternative) = .{ .original = c.alternatives };
        var default = c.default;
        for (order) |i| {
            if (i == c.alternatives.len) {
                default = (try self.elaborate(c.default.?, result)).term;
                continue;
            }
            const alternative = c.alternatives[i];
            const mark = self.scope.mark();
            defer self.scope.truncate(mark);

            const constructor = self.env.datatypes.constructorOf(&self.env.interner, alternative.constructor).?;
            for (alternative.binders, constructor.fields) |binder, field| {
                const at = try self.subst.instantiateWith(field, arguments);
                try self.scope.push(binder, .{ .monomorphic = at });
            }

            const elaborated_body = try self.elaborate(alternative.body, result);
            try alternatives.set(self.builder, i, .{
                .constructor = alternative.constructor,
                .binders = alternative.binders,
                .body = elaborated_body.term,
            }, !core.same(elaborated_body.term, alternative.body));
        }

        const unchanged = alternatives.copy == null and
            core.same(elaborated_scrutinee.term, c.scrutinee) and
            core.sameOptional(default, c.default);
        return .{
            .type = result,
            .term = if (unchanged) t else try self.builder.caseOf(.{
                .scrutinee = elaborated_scrutinee.term,
                .binder = c.binder,
                .alternatives = alternatives.copy orelse c.alternatives,
                .default = default,
            }, t.span),
        };
    }

    fn inBranchOrder(c: core.Case, a: usize, b: usize) bool {
        return branchStart(c, a) < branchStart(c, b);
    }

    fn branchStart(c: core.Case, i: usize) u32 {
        return startByte(if (i == c.alternatives.len) c.default.?.span else c.alternatives[i].body.span);
    }

    /// (T-Let)       Gamma |- e_1 => tau_1      sigma = Gen(Gamma, tau_1)
    ///               Gamma, x : sigma |- e_2 <= tau_2
    ///               ------------------------------------------------
    ///               Gamma |- let x = e_1 in e_2 <= tau_2
    ///
    /// A binding with a signature is checked against it, by T-Sig. One
    /// that is not closed is not generalized. See Local bindings in
    /// type_check.zig.
    fn let(self: *Inference, l: core.Let, t: core.Term, expected: ?types.Type) Error!Elaborated {
        if (self.env.interner.details(l.name).joinArity()) |arity| return try self.joinPoint(l, t, arity, expected);
        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        const value = if (self.env.annotationOf(l.name)) |declared| try self.signed(l.name, declared, l.value) else blk: {
            var out: [1]core.Term = undefined;
            _ = try self.localGroup(&.{.{ .name = l.name, .value = l.value }}, false, &out);
            break :blk out[0];
        };
        const body = try self.elaborate(l.body, expected);
        const unchanged = core.same(value, l.value) and core.same(body.term, l.body);
        return .{
            .type = body.type,
            .term = if (unchanged) t else try self.builder.let(l.name, value, body.term, t.span),
        };
    }

    /// (T-LetJoin)   Gamma |- \x_1 .. x_n -> u <= tau_1 -> .. -> tau_n -> tau
    ///               Gamma, j : tau_1 -> .. -> tau_n -> tau |- e <= tau
    ///               ------------------------------------------------
    ///               Gamma |- let j = \x_1 .. x_n -> u in e <= tau      (j is join(n))
    ///
    /// `j` is monomorphic, with `tau_i` fresh. Its value is elaborated in the
    /// enclosing frame.
    fn joinPoint(self: *Inference, l: core.Let, t: core.Term, arity: u32, expected: ?types.Type) Error!Elaborated {
        const result = expected orelse try self.subst.fresh(.type);
        const froms = try self.subst.arena.alloc(types.Type, arity);
        for (froms) |*from| from.* = try self.subst.fresh(.type);
        const join_type = try types.arrows(self.subst.arena, froms, result);
        const value = try self.elaborate(l.value, join_type);

        const mark = self.scope.mark();
        defer self.scope.truncate(mark);
        try self.scope.push(l.name, .{ .monomorphic = join_type });
        const body = try self.elaborate(l.body, result);

        const unchanged = core.same(value.term, l.value) and core.same(body.term, l.body);
        return .{
            .type = result,
            .term = if (unchanged) t else try self.builder.let(l.name, value.term, body.term, t.span),
        };
    }

    /// (T-LetRec)    Gamma, x_i : alpha_i |- e_i <= alpha_i      (each i)
    ///               sigma_i = Gen(Gamma, alpha_i)              (each i)
    ///               Gamma, x_i : sigma_i |- body <= result
    ///               ------------------------------------------------------
    ///               Gamma |- letrec {x_i = e_i} in body <= result
    ///
    /// The members without a signature are inferred one dependency group
    /// at a time, a use of a signed member being no dependency, then each
    /// signed member is checked against its signature. A group with a member
    /// that is not closed is not generalized. See Local bindings in
    /// type_check.zig.
    fn letrec(self: *Inference, l: core.Letrec, t: core.Term, expected: ?types.Type) Error!Elaborated {
        const mark = self.scope.mark();
        defer self.scope.truncate(mark);

        const values = try self.builder.slice(core.Term, l.bindings.len);
        var shared: std.ArrayList(core.Letrec.Binding) = .empty;
        defer shared.deinit(self.gpa);

        var unsigned: std.ArrayList(u32) = .empty;
        defer unsigned.deinit(self.gpa);
        var inferred: std.ArrayList(core.Letrec.Binding) = .empty;
        defer inferred.deinit(self.gpa);
        for (l.bindings, 0..) |b, i| {
            if (self.env.annotationOf(b.name) != null) continue;
            try unsigned.append(self.gpa, @intCast(i));
            try inferred.append(self.gpa, b);
        }
        const edges = try core.free.references(self.gpa, inferred.items);
        defer {
            for (edges) |e| self.gpa.free(e);
            self.gpa.free(edges);
        }
        var found = try core.components.stronglyConnectedComponents(self.gpa, edges);
        defer found.deinit();

        for (found.groups) |members| {
            const bindings = try self.gpa.alloc(core.Letrec.Binding, members.len);
            defer self.gpa.free(bindings);
            const out = try self.gpa.alloc(core.Term, members.len);
            defer self.gpa.free(out);
            for (members, bindings) |k, *b| b.* = inferred.items[k];
            const recursive = core.components.cyclic(members, edges);
            if (try self.localGroup(bindings, recursive, out)) |binding| try shared.append(self.gpa, binding);
            for (members, out) |k, value| values[unsigned.items[k]] = value;
        }
        for (l.bindings, values) |b, *value| {
            const declared = self.env.annotationOf(b.name) orelse continue;
            value.* = try self.signed(b.name, declared, b.value);
        }

        const body = try self.elaborate(l.body, expected);
        var bindings: core.Rebuilt(core.Letrec.Binding) = .{ .original = l.bindings };
        for (l.bindings, values, 0..) |b, value, i| {
            try bindings.set(self.builder, i, .{ .name = b.name, .value = value }, !core.same(value, b.value));
        }
        const unchanged = bindings.copy == null and shared.items.len == 0 and core.same(body.term, l.body);
        if (unchanged) return .{ .type = body.type, .term = t };
        const rebuilt = try std.mem.concat(self.builder.allocator, core.Letrec.Binding, &.{ bindings.copy orelse l.bindings, shared.items });
        return .{ .type = body.type, .term = try self.builder.letrec(rebuilt, body.term, t.span) };
    }

    /// Infers `bindings`, one local group, writing each member's elaborated
    /// value to `out` and leaving each in scope. `recursive` says whether a
    /// member reads one of the group. Returns the binding the members select
    /// from, when there is one.
    fn localGroup(self: *Inference, bindings: []const core.Letrec.Binding, recursive: bool, out: []core.Term) Error!?core.Letrec.Binding {
        for (bindings) |b| {
            if (self.mentionsMonomorphic(b.value)) break;
        } else {
            var group = try Group.init(self.gpa, bindings.len);
            defer group.deinit(self.gpa);
            for (bindings, group.spans()) |b, *span| span.* = b.value.span;
            const quantified = try self.inferGroup(bindings, false, &group);
            const shared = try self.close(&group, bindings, quantified, recursive, out);
            for (bindings, group.generalized()) |b, g| try self.bindGeneralized(b.name, g);
            return shared;
        }

        const placeholders = try self.subst.arena.alloc(types.Type, bindings.len);
        for (bindings, placeholders) |b, *p| {
            p.* = try self.subst.fresh(.type);
            try self.scope.push(b.name, .{ .monomorphic = p.* });
        }
        for (bindings, placeholders, out) |b, p, *value| value.* = (try self.elaborate(b.value, p)).term;
        return null;
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
    };

    /// Binds the group's context as the givens of every member's frame, one
    /// dictionary parameter per constraint shared by all of them. Returns
    /// those parameters.
    fn bindContext(self: *Inference, group: *Group) Error![]const core.SymbolId {
        const frames = group.frames();
        const dictionaries = try self.parameters(frames[0], group.generalized()[0].context);
        for (frames[1..]) |f| {
            for (self.evidence.get(frames[0]).givens.items) |g| try self.evidence.give(f, g);
        }
        return dictionaries;
    }

    /// Solves the wanteds of `group`, whose bindings are `bindings` and
    /// which quantifies `quantified`, under its context, and writes to `out`
    /// each member abstracted over the group's dictionaries. `recursive`
    /// says whether a member reads one of the group. Returns the binding the
    /// members select from, when there is one. See Recursive groups in
    /// type_check.zig.
    fn close(
        self: *Inference,
        group: *Group,
        bindings: []const core.Letrec.Binding,
        quantified: []const types.Meta,
        recursive: bool,
        out: []core.Term,
    ) Error!?core.Letrec.Binding {
        const dictionaries = try self.bindContext(group);
        const frames = group.frames();
        for (frames) |f| try self.solve(f, quantified);
        const values = group.values();
        if (dictionaries.len == 0 or !recursive) {
            for (out, values, frames) |*slot, value, frame| {
                slot.* = try self.builder.abstract(dictionaries, try self.evidence.wrap(self.builder, frame, value));
            }
            return null;
        }

        // Each member's monomorphic copy, its recursive uses renamed to the
        // copies.
        var copies: evidence.Replacements = .empty;
        defer copies.deinit(self.gpa);
        const inner = try self.builder.slice(core.Letrec.Binding, bindings.len);
        for (bindings, inner) |b, *copy| {
            copy.name = try self.env.interner.fresh(self.env.interner.spelling(b.name));
            try copies.put(self.gpa, b.name, self.builder.symbol(copy.name, b.value.span));
        }
        for (inner, values) |*copy, value| copy.value = try evidence.substitute(self.builder, value, &copies);

        const span = bindings[0].value.span;
        if (inner.len == 1) {
            out[0] = try self.abstractGroup(dictionaries, frames, inner, self.builder.symbol(inner[0].name, span));
            return null;
        }

        const k = try self.env.interner.fresh("k");
        var tuple = self.builder.symbol(k, span);
        for (inner) |copy| tuple = try self.builder.apply(tuple, self.builder.symbol(copy.name, span), span);
        const group_value = try self.abstractGroup(dictionaries, frames, inner, try self.builder.lambda(k, tuple, span));

        const name = try self.env.interner.fresh("group");
        for (out, 0..) |*slot, i| {
            const received = try self.builder.slice(core.SymbolId, dictionaries.len);
            for (received) |*d| d.* = try self.env.interner.fresh("d");
            const components = try self.builder.slice(core.SymbolId, inner.len);
            for (components) |*field| field.* = try self.env.interner.fresh("_");
            const select = try self.builder.abstract(components, self.builder.symbol(components[i], span));
            var applied = self.builder.symbol(name, span);
            for (received) |d| applied = try self.builder.apply(applied, self.builder.symbol(d, span), span);
            slot.* = try self.builder.abstract(received, try self.builder.apply(applied, select, span));
        }
        return .{ .name = name, .value = group_value };
    }

    /// `\dictionaries -> lets(frames) letrec inner in result`.
    fn abstractGroup(
        self: *Inference,
        dictionaries: []const core.SymbolId,
        frames: []const u32,
        inner: []const core.Letrec.Binding,
        result: core.Term,
    ) Error!core.Term {
        var body = try self.builder.letrec(inner, result, result.span);
        for (frames) |frame| body = try self.evidence.wrap(self.builder, frame, body);
        return try self.builder.abstract(dictionaries, body);
    }

    /// Infer a group of mutually recursive bindings and generalize them
    /// together, writing each one's generalization, frame and elaborated
    /// body to `group`. Generalization reports against `group`'s spans.
    ///
    /// Returns the metavariables the group quantifies.
    fn inferGroup(
        self: *Inference,
        bindings: []const core.Letrec.Binding,
        restricted: bool,
        group: *Group,
    ) Error![]const types.Meta {
        const spans = group.spans();
        const frames = group.frames();
        const placeholders = try self.gpa.alloc(types.Type, bindings.len);
        defer self.gpa.free(placeholders);

        {
            self.subst.level += 1;
            defer self.subst.level -= 1;
            for (bindings, placeholders) |b, *p| p.* = switch (self.env.interner.details(b.name)) {
                .matcher => |m| try self.matcherShape(m.arity),
                else => try self.subst.fresh(.type),
            };

            const mark = self.scope.mark();
            defer self.scope.truncate(mark);
            for (bindings, placeholders) |b, p| {
                try self.scope.push(b.name, .{ .member = p });
            }

            // Each body is checked against its placeholder.
            for (bindings, placeholders, frames, group.values()) |b, p, *frame, *value| {
                frame.* = try self.implication();
                value.* = (try self.elaborateIn(frame.*, b.value, p)).term;
            }
        }

        return try self.generalizeGroup(placeholders, spans, frames, restricted, group.generalized());
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
        /// The group's context, over those metavariables.
        context: []const types.TypeClassConstraint,
        /// Whether its type was poisoned before it was generalized.
        poisoned: bool,
    };

    /// `Gen(Gamma, tau_i)` for every member of a group checked together,
    /// whose wanteds are those of `frames`.
    ///
    /// Each member quantifies the metavariables free in its own type and
    /// deeper than the current level. See Levels in type_check.zig.
    ///
    /// The group has one context: each wanted is reduced through instances
    /// to its residuals, and the context is those mentioning a quantified
    /// metavariable, without duplicates or those a superclass of another
    /// implies. Every member takes the whole context, quantifying the
    /// metavariables it mentions. The wanteds are solved under it by
    /// `solve`, once the caller has bound it as givens.
    ///
    /// A `restricted` group, one with a member written without parameters,
    /// quantifies none of the metavariables its context mentions. They move
    /// to the current level, so the group's uses fix them, and their wanteds
    /// float to the enclosing frame. See Monomorphism restriction in
    /// type_check.zig.
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
        restricted: bool,
        out: []Generalized,
    ) Error![]const types.Meta {
        var quantified: std.ArrayList(types.Meta) = .empty;
        defer quantified.deinit(self.gpa);
        const bounds = try self.gpa.alloc(usize, group.len + 1);
        defer self.gpa.free(bounds);
        try self.collectQuantified(group, &quantified, bounds);

        const residuals = try self.groupContext(frames, quantified.items);
        defer self.gpa.free(residuals);
        var context: []const types.TypeClassConstraint = residuals;
        if (restricted and residuals.len > 0) {
            try self.poisonUnfixable(group, residuals, quantified.items, bounds);
            for (residuals) |c| _ = self.subst.promote(c.type, self.subst.level);
            try self.collectQuantified(group, &quantified, bounds);
            context = &.{};
        }

        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
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
                .context = try self.builder.dupeSlice(types.TypeClassConstraint, context),
                .poisoned = self.subst.isPoisoned(t),
            };
        }
        return try self.builder.dupeSlice(types.Meta, quantified.items);
    }

    /// Poisons each metavariable of `residuals` that a poisoned member of
    /// `group` mentions and no other member does. See Poisoned types in
    /// type_check.zig.
    ///
    /// Preconditions:
    /// - `quantified[bounds[i]..bounds[i + 1]]` are the metavariables
    ///   `group[i]` mentions.
    fn poisonUnfixable(
        self: *Inference,
        group: []const types.Type,
        residuals: []const types.TypeClassConstraint,
        quantified: []const types.Meta,
        bounds: []const usize,
    ) Error!void {
        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        for (residuals) |c| try self.subst.freeMetas(c.type, &free);
        for (free.items) |id| {
            var failed = false;
            var fixed = false;
            for (group, 0..) |t, i| {
                if (std.mem.indexOfScalar(types.Meta, quantified[bounds[i]..bounds[i + 1]], id) == null) continue;
                if (self.subst.isPoisoned(t)) failed = true else fixed = true;
            }
            if (failed and !fixed) self.subst.poison(.{ .meta = id });
        }
    }

    /// The group context of the wanteds of `frames`: each residual
    /// mentioning one of `quantified`, without duplicates or constraints
    /// another's superclasses imply, in order of first appearance. The
    /// caller owns the result.
    ///
    /// Reports a residual as ambiguous at its origin when it mentions a
    /// metavariable deeper than the current level and outside `quantified`:
    /// no type of the group or its environment mentions it, so nothing can
    /// determine it.
    fn groupContext(
        self: *Inference,
        frames: []const u32,
        quantified: []const types.Meta,
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
                    if (try self.undetermined(r.type, quantified)) {
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

    /// Whether `t` mentions a metavariable deeper than the current level
    /// that is not one of `quantified`.
    fn undetermined(self: *Inference, t: types.Type, quantified: []const types.Meta) Error!bool {
        var deeper: std.ArrayList(types.Meta) = .empty;
        defer deeper.deinit(self.gpa);
        try self.deeperMetas(t, &deeper);
        for (deeper.items) |id| {
            if (std.mem.indexOfScalar(types.Meta, quantified, id) == null) return true;
        }
        return false;
    }

    /// Lays end to end in `quantified` the metavariables each of `group`
    /// quantifies: member `i`'s are `quantified[bounds[i]..bounds[i + 1]]`.
    fn collectQuantified(self: *Inference, group: []const types.Type, quantified: *std.ArrayList(types.Meta), bounds: []usize) Error!void {
        quantified.clearRetainingCapacity();
        for (group, 0..) |t, i| {
            bounds[i] = quantified.items.len;
            try self.deeperMetas(t, quantified);
        }
        bounds[group.len] = quantified.items.len;
    }

    /// Appends to `out` each metavariable free in `t` and deeper than the
    /// current level, whether or not `out` already holds it.
    fn deeperMetas(self: *Inference, t: types.Type, out: *std.ArrayList(types.Meta)) Error!void {
        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.subst.freeMetas(t, &free);
        for (free.items) |id| {
            if (self.subst.levelOf(id) > self.subst.level) try out.append(self.gpa, id);
        }
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
            if (self.evidence.solvedIn(at, w.class, settled)) |earlier| {
                try self.evidence.bind(at, w.evidence, self.builder.symbol(earlier, w.origin));
                continue;
            }
            switch (try self.solveOne(at, w, quantified)) {
                .solved => |e| {
                    try self.evidence.bind(at, w.evidence, e);
                    try self.evidence.solve(at, .{ .class = w.class, .type = settled, .evidence = w.evidence });
                },
                .refuted => |culprit| try self.reportUnsolved(at, w, .{ .class = w.class, .type = culprit }, true),
                .stuck => |leaf| try self.reportUnsolved(at, w, leaf, false),
            }
        }
    }

    /// The frame enclosing `at`, when a wanted on `t` floats there: it
    /// mentions none of `quantified` and none of `at`'s skolems.
    fn floatsTo(self: *Inference, at: u32, t: types.Type, quantified: []const types.Meta) Error!?u32 {
        const frame = self.evidence.get(at);
        const parent = frame.parent orelse return null;
        if (try self.subst.mentionsAny(t, quantified)) return null;
        if (self.subst.mentionsSkolemFrom(t, frame.level)) return null;
        return parent;
    }

    fn solveOne(self: *Inference, at: u32, w: evidence.Wanted, quantified: []const types.Meta) Error!classes.Solution(core.Term) {
        var givens: std.ArrayList(classes.Given(core.Term)) = .empty;
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

        pub fn leaf(self: Float, class: classes.ClassId, t: types.Type, span: diagnostic.Span) Error!?core.Term {
            const i = self.inference;
            const parent = try i.floatsTo(self.at, t, self.quantified) orelse return null;
            return i.builder.symbol(try i.raise(parent, class, t, span), span);
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
        if (frame.signature) |binder| if (self.subst.mentionsSkolemFrom(needed.type, frame.level)) {
            return try self.report(.signature_mismatch, w.origin, .{ .not_given = .{ .needed = needed, .binder = binder } });
        };
        try self.report(.ambiguous_constraint, w.origin, .{ .ambiguous = needed });
    }

    /// Infers one strongly connected component of the definition graph
    /// leaving each member's generalized scheme in `inferred` and its
    /// elaborated body in `elaborated`.
    ///
    /// T-LetRec at top level: placeholders, bodies, unify, generalize
    /// together. Mutual recursion works because every member is in scope
    /// monomorphically while any body is checked. A definition with a
    /// signature is a component of its own, checked by T-Sig, and every use
    /// of it, its own included, is at the signature.
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
        if (members.len == 1) {
            const definition = definitions[members[0]];
            if (self.env.annotationOf(definition.symbol)) |declared| {
                try self.inferred.put(definition.symbol, declared.scheme);
                const elaborated = try self.signed(definition.symbol, declared, definition.body);
                if (!core.same(elaborated, definition.body)) try self.elaborated.put(definition.symbol, elaborated);
                return;
            }
        }

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
        var restricted = false;
        for (members) |index| restricted = restricted or definitions[index].simple;
        const quantified = try self.inferGroup(bindings, restricted, &group);

        for (members, group.generalized()) |index, g| {
            const symbol = definitions[index].symbol;
            try self.inferred.put(symbol, g.scheme);
            if (g.poisoned) try self.failed.put(self.gpa, symbol, {});
        }
        const recursive = members.len > 1 or core.free.occurs(bindings[0].value, bindings[0].name);
        const closed = try self.builder.slice(core.Term, members.len);
        if (try self.close(&group, bindings, quantified, recursive, closed)) |shared| {
            const first = definitions[members[0]];
            self.env.interner.globalize(shared.name, self.env.interner.moduleOf(first.symbol).?);
            try self.shared.append(self.gpa, .{ .symbol = shared.name, .body = shared.value, .span = first.span });
        }
        for (members, closed) |index, elaborated| {
            const definition = definitions[index];
            if (!core.same(elaborated, definition.body)) try self.elaborated.put(definition.symbol, elaborated);
        }
    }

    /// (T-Sig)   sigma = forall a_bar. Q => tau      a_bar fresh rigid
    ///           Gamma |- e <= tau  ~>  W
    ///           ----------------------------------
    ///           Gamma |- (f :: sigma; f = e)  ~>  forall a_bar. (Q => W)
    ///
    /// Checks `value` against `declared`, `binder`'s signature, in an
    /// implication one level deeper whose skolems are the signature's
    /// variables and whose givens are its context. Returns the elaborated
    /// value, abstracted over the context's dictionaries.
    fn signed(self: *Inference, binder: core.SymbolId, declared: core.env.Env.Annotation, value: core.Term) Error!core.Term {
        const frame, const term, const bound = blk: {
            self.subst.level += 1;
            defer self.subst.level -= 1;
            const frame = try self.implication();
            self.evidence.get(frame).signature = binder;

            const scheme = declared.scheme;
            const skolems = try self.subst.arena.alloc(types.Type, scheme.variables.len);
            for (skolems, scheme.variables, 0..) |*skolem, kind, i| {
                const spelling = if (i < declared.names.len) declared.names[i] else try types.variableSpelling(self.subst.arena, i);
                skolem.* = try self.subst.skolem(spelling, kind, binder);
            }
            const context = try self.subst.arena.alloc(types.TypeClassConstraint, scheme.constraints.len);
            for (scheme.constraints, context) |c, *slot| {
                slot.* = .{ .class = c.class, .type = try self.subst.instantiateWith(c.type, skolems) };
            }
            const bound = try self.parameters(frame, context);

            const body = try self.elaborateIn(frame, value, try self.subst.instantiateWith(scheme.type, skolems));
            break :blk .{ frame, body.term, bound };
        };
        try self.solve(frame, &.{});
        return try self.builder.abstract(bound, try self.evidence.wrap(self.builder, frame, term));
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
    /// then the wanteds left at the top.
    pub fn check(self: *Inference, p: *const core.Program) Error!void {
        try self.program(p.definitions, p.components);
        try self.superclasses();
        try self.solve(evidence.top, &.{});
    }

    /// Solves each superclass of each instance, in a frame whose givens are
    /// the instance's context.
    fn superclasses(self: *Inference) Error!void {
        const registry = &self.env.classes;
        for (registry.instances.items, 0..) |instance, i| {
            const id: classes.InstanceId = @enumFromInt(i);
            const class = registry.get(instance.class);
            const frame = try self.evidence.frame(null, 0);
            self.evidence.get(frame).instance = id;

            const context = try self.subst.arena.alloc(types.TypeClassConstraint, instance.context.len);
            for (instance.context, context) |r, *slot| slot.* = r.constraint();
            const dictionaries = try self.parameters(frame, context);

            const selected = try self.builder.slice(core.SymbolId, class.superclasses.len);
            for (class.superclasses, selected) |super, *s| s.* = try self.raise(frame, super, instance.type, instance.span);
            try self.solve(frame, &.{});
            try self.instances.append(self.gpa, .{ .id = id, .frame = frame, .parameters = dictionaries, .superclasses = selected });
        }
    }

    /// The generalized scheme of a definition, once its component is done.
    pub fn schemeOf(self: *const Inference, id: core.SymbolId) ?types.Scheme {
        return self.inferred.get(id);
    }

    /// Replaces each definition's body in `linked` with its elaborated one,
    /// and appends the evidence solved at the top, the selectors, and the
    /// instance dictionaries.
    pub fn finish(self: *Inference, linked: *core.Program) Error!void {
        if (self.elaborated.entries.items.len == 0) return;

        var definitions: std.ArrayList(core.Definition) = .empty;
        defer definitions.deinit(self.gpa);
        try definitions.appendSlice(self.gpa, linked.definitions);
        for (definitions.items) |*d| d.body = self.elaborated.get(d.symbol) orelse d.body;
        try definitions.appendSlice(self.gpa, self.shared.items);
        const module = self.env.interner.moduleOf(linked.entry).?;
        for (self.evidence.get(evidence.top).bindings.items) |b| {
            self.env.interner.globalize(b.name, module);
            try definitions.append(self.gpa, .{ .symbol = b.name, .body = b.value, .span = b.value.span });
        }
        try evidence.dictionaries(self.builder, &self.env.classes, self.env, &self.evidence, self.instances.items, &definitions, self.gpa);
        linked.definitions = try self.builder.dupeSlice(core.Definition, definitions.items);
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
            .not_given => |n| try self.reportAbout(category, span, detail, &.{n.needed.type}),
            .superclass => |sc| try self.reportAbout(category, span, detail, &.{sc.needed.type}),
            .over_application, .not_a_function, .view_not_function => |t| try self.reportAbout(category, span, detail, &.{t}),
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
        // A restricted binding's scheme mentions the metavariables its uses
        // fixed.
        const settled = try subst.resolveScheme(entry.value);
        try program.env.setScheme(entry.id, try settled.clone(program.env.allocator()));
    }
}

fn inSourceOrder(_: void, a: Failure, b: Failure) bool {
    if (a.span.source != b.span.source) return @intFromEnum(a.span.source) < @intFromEnum(b.span.source);
    return startByte(a.span) < startByte(b.span);
}

/// The span's first byte, or 0 when it has no range.
fn startByte(span: diagnostic.Span) u32 {
    return if (span.range) |r| r.start_byte else 0;
}

fn render(
    gpa: Allocator,
    subst: *Substitution,
    env: *core.env.Env,
    failure: Failure,
    sink: *diagnostic.Sink,
) !void {
    var message: diagnostic.Message = .init(sink.allocator);
    defer message.deinit();

    switch (failure.detail) {
        .mismatch => |m| {
            const expected = try subst.resolveDeep(m.expected);
            const found = try subst.resolveDeep(m.found);
            var names = try env.messageNames(gpa, &.{ expected, found }, &.{});
            defer names.deinit(gpa);
            try message.append(.{ "Expected ", diagnostic.code(expected.named(&names)), ", found ", diagnostic.code(found.named(&names)), "." });
            if (m.skolem) |k| try message.append(.{ " ", diagnostic.code(k.spelling), " is rigid, bound by the signature of ", diagnostic.code(env.interner.spelling(k.binder)), "." });
        },
        .violation => |v| {
            const t = try subst.resolveDeep(v.type);
            var names = try env.messageNames(gpa, &.{t}, &.{v.class});
            defer names.deinit(gpa);
            try message.append(.{ diagnostic.code(.{ names.class(&env.classes, v.class), " ", t.namedOperand(&names) }), " is not satisfied." });
        },
        .not_given => |n| {
            const t = try subst.resolveDeep(n.needed.type);
            var names = try env.messageNames(gpa, &.{t}, &.{n.needed.class});
            defer names.deinit(gpa);
            try message.append(.{ diagnostic.code(.{ names.class(&env.classes, n.needed.class), " ", t.namedOperand(&names) }), " is needed, but the signature of ", diagnostic.code(env.interner.spelling(n.binder)), " does not give it." });
        },
        .ambiguous => |c| {
            const t = try subst.resolveDeep(c.type);
            var names = try env.messageNames(gpa, &.{t}, &.{c.class});
            defer names.deinit(gpa);
            try message.append(.{ diagnostic.code(.{ names.class(&env.classes, c.class), " ", t.namedOperand(&names) }), " is ambiguous: nothing determines its type." });
        },
        .superclass => |s| {
            const instance = env.classes.instance(s.instance);
            const needed = try subst.resolveDeep(s.needed.type);
            var names = try env.messageNames(gpa, &.{ instance.type, needed }, &.{ instance.class, s.needed.class });
            defer names.deinit(gpa);
            try message.append(.{ diagnostic.code(.{ names.class(&env.classes, instance.class), " ", instance.type.namedOperand(&names) }), " needs ", diagnostic.code(.{ names.class(&env.classes, s.needed.class), " ", needed.namedOperand(&names) }) });
        },
        inline .over_application, .view_not_function, .not_a_function => |shown, tag| {
            const t = try subst.resolveDeep(shown);
            var names = try env.messageNames(gpa, &.{t}, &.{});
            defer names.deinit(gpa);
            const shown_code = diagnostic.code(t.named(&names));
            try message.append(switch (tag) {
                .over_application => .{ shown_code, " has no argument left to take." },
                .view_not_function => .{ "The expression of a view pattern must be a function; found ", shown_code, "." },
                .not_a_function => .{ shown_code, " is not a function." },
                else => comptime unreachable,
            });
        },
        .unbound => |id| try message.append(.{ diagnostic.code(env.interner.spelling(id)), " is not defined." }),
        .too_many_variables => |n| try message.append(.{ "The type has ", n, " variables, more than the ", std.math.maxInt(types.TypeVar), " a scheme can quantify." }),
    }

    try sink.add(failure.category, failure.span, &message);
}
