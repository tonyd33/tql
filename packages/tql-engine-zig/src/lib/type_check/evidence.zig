//! Dictionary passing: the evidence inference leaves behind, and the Core it
//! becomes.
//!
//! Inference applies each use of a constrained name to one placeholder per
//! dictionary constraint, and wraps each generalized body in one dictionary
//! lambda per constraint it quantifies. Once every type is known, each
//! placeholder resolves to a dictionary in scope, a superclass selected from
//! one, or an instance applied to the evidence for its context.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const classes = core.classes;
const types = core.types;

const primitives = @import("../primitives.zig");

const Allocator = std.mem.Allocator;
const Substitution = @import("substitution.zig").Substitution;

/// A dictionary in scope: a parameter of an enclosing generalized body, or of
/// an instance's dictionary.
pub const Given = struct {
    class: classes.ClassId,
    /// A metavariable or a bound variable.
    type: types.Type,
    evidence: core.SymbolId,
};

/// One generalized body, and the dictionaries it binds.
pub const Frame = struct {
    parent: ?u32,
    givens: std.ArrayList(Given) = .empty,
};

/// A symbol standing for evidence inference cannot build yet.
pub const Placeholder = struct {
    symbol: core.SymbolId,
    /// The innermost generalized body it was raised in.
    frame: ?u32,
    span: diagnostic.Span,
    wanted: Wanted,

    pub const Wanted = union(enum) {
        /// Evidence for `class type`.
        constraint: types.TypeClassConstraint,
        /// A use of a member of the recursive group being inferred, which
        /// becomes the member applied to evidence for each of its group's
        /// dictionary constraints.
        member: core.SymbolId,
    };
};

pub const Table = struct {
    gpa: Allocator,
    frames: std.ArrayList(Frame) = .empty,
    placeholders: std.ArrayList(Placeholder) = .empty,
    /// The dictionary constraints each member of an inferred group takes, in
    /// parameter order.
    parameters: core.SymbolTable([]const types.TypeClassConstraint),

    pub fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa, .parameters = .init(gpa) };
    }

    pub fn deinit(self: *Table) void {
        for (self.frames.items) |*f| f.givens.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.placeholders.deinit(self.gpa);
        self.parameters.deinit();
    }

    pub fn frame(self: *Table, parent: ?u32) Allocator.Error!u32 {
        try self.frames.append(self.gpa, .{ .parent = parent });
        return @intCast(self.frames.items.len - 1);
    }

    pub fn give(self: *Table, at: u32, given: Given) Allocator.Error!void {
        try self.frames.items[at].givens.append(self.gpa, given);
    }

    pub fn want(self: *Table, placeholder: Placeholder) Allocator.Error!void {
        try self.placeholders.append(self.gpa, placeholder);
    }
};

/// Why a placeholder has no evidence.
pub const Unresolved = struct {
    reason: enum {
        /// Its type was never determined.
        ambiguous,
        /// No instance or dictionary in scope provides it.
        unsatisfied,
    },
    constraint: types.TypeClassConstraint,
    span: diagnostic.Span,
};

/// Builds evidence once inference is done.
pub const Resolver = struct {
    table: *Table,
    subst: *Substitution,
    registry: *const classes.Registry,
    /// Where `select[l]` symbols are interned.
    env: *core.env.Env,
    builder: core.Builder,
    gpa: Allocator,
    /// Set when `resolve` fails.
    unresolved: ?Unresolved = null,

    pub const Error = Allocator.Error || error{Unresolved};

    /// Evidence for `class t`, seen from inside frame `at`.
    pub fn resolve(
        self: *Resolver,
        class: classes.ClassId,
        t: types.Type,
        at: ?u32,
        span: diagnostic.Span,
    ) Error!core.Term {
        const target = try self.subst.normalize(t);
        switch (target) {
            .meta, .variable, .application => {
                if (try self.given(class, target, at, span)) |found| return found;
                return self.fail(.ambiguous, class, t, span);
            },
            .constructor => {},
            .record => |r| {
                if (class != .eq) return self.fail(.unsatisfied, class, t, span);
                return try self.recordDictionary(r, at, span);
            },
            else => return self.fail(.unsatisfied, class, t, span),
        }

        const id = self.registry.instanceFor(class, target.constructor.name) orelse
            return self.fail(.unsatisfied, class, t, span);
        const instance = self.registry.instance(id);
        var result = self.builder.symbol(instance.dictionary.?, span);
        for (instance.context) |c| {
            if (self.registry.evidenceOf(c.class) != .dictionary) continue;
            const argument = target.constructor.arguments[c.variable];
            result = try self.builder.apply(result, try self.resolve(c.class, argument, at, span), span);
        }
        return result;
    }

    /// `dict[Eq] (\x y -> ...)`, comparing the fields of `r` through their own
    /// dictionaries, then its rest through the rest's.
    ///
    /// A dictionary for a row compares that row's labels only, on any record
    /// that has them.
    fn recordDictionary(self: *Resolver, r: types.Type.Record, at: ?u32, span: diagnostic.Span) Error!core.Term {
        const b = self.builder;
        const eq = self.registry.get(.eq);
        const declared = &self.env.datatypes;
        const x = try self.env.interner.fresh("x");
        const y = try self.env.interner.fresh("y");

        var result: ?core.Term = if (r.rest) |rest|
            try self.compared(eq.methods[0], try self.resolve(.eq, rest.*, at, span), b.symbol(x, span), b.symbol(y, span), span)
        else
            null;
        var i = r.fields.len;
        while (i > 0) {
            i -= 1;
            const f = r.fields[i];
            const select = try primitives.selectSymbol(self.env, f.label);
            const pair = try self.compared(
                eq.methods[0],
                try self.resolve(.eq, f.type.*, at, span),
                try b.apply(b.symbol(select, span), b.symbol(x, span), span),
                try b.apply(b.symbol(select, span), b.symbol(y, span), span),
                span,
            );
            result = if (result) |rest|
                try b.choose(declared, pair, b.symbol(declared.boolConstructor(false).symbol, span), rest, span)
            else
                pair;
        }
        const method = try b.abstract(&.{ x, y }, result orelse b.symbol(declared.boolConstructor(true).symbol, span));
        return try b.apply(b.symbol(eq.constructor.?, span), method, span);
    }

    /// `method dictionary left right`.
    fn compared(self: *Resolver, method: core.SymbolId, dictionary: core.Term, left: core.Term, right: core.Term, span: diagnostic.Span) Error!core.Term {
        return try self.builder.applyMany(self.builder.symbol(method, span), &.{ dictionary, left, right }, span);
    }

    /// A dictionary in scope for `class` at `target`, directly or through
    /// superclass selectors.
    fn given(
        self: *Resolver,
        class: classes.ClassId,
        target: types.Type,
        at: ?u32,
        span: diagnostic.Span,
    ) Error!?core.Term {
        var path: std.ArrayList(core.SymbolId) = .empty;
        defer path.deinit(self.gpa);
        const wanted = try self.subst.resolveDeep(target);
        var current = at;
        while (current) |f| : (current = self.table.frames.items[f].parent) {
            for (self.table.frames.items[f].givens.items) |g| {
                if (!types.eql(try self.subst.resolveDeep(g.type), wanted)) continue;
                path.clearRetainingCapacity();
                if (!try self.registry.superclassPath(g.class, class, &path, self.gpa)) continue;
                var result = self.builder.symbol(g.evidence, span);
                for (path.items) |selector| {
                    result = try self.builder.apply(self.builder.symbol(selector, span), result, span);
                }
                return result;
            }
        }
        return null;
    }

    fn fail(
        self: *Resolver,
        reason: @FieldType(Unresolved, "reason"),
        class: classes.ClassId,
        t: types.Type,
        span: diagnostic.Span,
    ) Error {
        self.unresolved = .{ .reason = reason, .constraint = .{ .class = class, .type = t }, .span = span };
        return error.Unresolved;
    }

    /// Every placeholder's evidence, by its symbol.
    pub fn resolveAll(self: *Resolver, out: *Replacements) Error!void {
        for (self.table.placeholders.items) |p| {
            const result = switch (p.wanted) {
                .constraint => |c| try self.resolve(c.class, c.type, p.frame, p.span),
                .member => |member| blk: {
                    var term = self.builder.symbol(member, p.span);
                    for (self.table.parameters.get(member) orelse &.{}) |c| {
                        term = try self.builder.apply(term, try self.resolve(c.class, c.type, p.frame, p.span), p.span);
                    }
                    break :blk term;
                },
            };
            try out.put(self.gpa, p.symbol, result);
        }
    }

    /// Appends the definitions dictionary passing needs beside the program's
    /// own: each class's selectors, and each instance's dictionary.
    pub fn dictionaries(self: *Resolver, env: *core.env.Env, out: *std.ArrayList(core.Definition)) Error!void {
        const builder = self.builder;
        const registry = self.registry;

        for (registry.classes.items) |class| {
            const constructor = class.constructor orelse continue;
            const fields = class.selectors.len + class.methods.len;
            for (class.selectors, 0..) |selector, i| try out.append(self.gpa, try field(builder, env, selector.symbol, constructor, fields, i, class.span));
            for (class.methods, class.selectors.len..) |method, i| try out.append(self.gpa, try field(builder, env, method, constructor, fields, i, class.span));
        }

        for (registry.instances.items) |instance| {
            const dictionary = instance.dictionary orelse continue;
            const class = registry.get(instance.class);
            const span = instance.span;
            const at = try self.table.frame(null);
            const parameters = try builder.slice(core.SymbolId, registry.dictionaryCount(instance.context));
            const arguments = try builder.slice(core.Term, parameters.len);
            var i: usize = 0;
            for (instance.context) |c| {
                if (registry.evidenceOf(c.class) != .dictionary) continue;
                parameters[i] = try env.interner.fresh("d");
                arguments[i] = builder.symbol(parameters[i], span);
                try self.table.give(at, .{ .class = c.class, .type = types.variable_type(c.variable), .evidence = parameters[i] });
                i += 1;
            }

            var body = builder.symbol(class.constructor.?, span);
            for (class.selectors) |selector| {
                body = try builder.apply(body, try self.resolve(selector.superclass, instance.type, at, span), span);
            }
            for (instance.methods) |implementation| {
                body = try builder.apply(body, try builder.applyMany(builder.symbol(implementation, span), arguments, span), span);
            }
            try out.append(self.gpa, .{
                .symbol = dictionary,
                .body = try builder.abstract(parameters, body),
                .span = span,
            });
        }
    }
};

/// Each placeholder's evidence, by its symbol.
pub const Replacements = std.AutoHashMapUnmanaged(core.SymbolId, core.Term);

/// `original`, copied on the first `set` whose element changed.
pub fn Rebuilt(comptime T: type) type {
    return struct {
        original: []const T,
        copy: ?[]T = null,

        pub fn set(self: *@This(), builder: core.Builder, i: usize, value: T, changed: bool) Allocator.Error!void {
            if (self.copy == null) {
                if (!changed) return;
                self.copy = try builder.dupeSlice(T, self.original);
            }
            self.copy.?[i] = value;
        }
    };
}

/// `t` with each symbol `replacements` has an entry for replaced by it.
/// Shares every subtree with nothing replaced.
pub fn substitute(
    builder: core.Builder,
    t: core.Term,
    replacements: *const Replacements,
) Allocator.Error!core.Term {
    switch (t.kind) {
        .symbol => |id| return replacements.get(id) orelse t,
        .literal => return t,
        .lambda => |l| {
            const body = try substitute(builder, l.body, replacements);
            if (same(body, l.body)) return t;
            return try builder.lambda(l.parameter, body, t.span);
        },
        .apply => |a| {
            const function = try substitute(builder, a.function, replacements);
            const argument = try substitute(builder, a.argument, replacements);
            if (same(function, a.function) and same(argument, a.argument)) return t;
            return try builder.apply(function, argument, t.span);
        },
        .case => |c| {
            const scrutinee = try substitute(builder, c.scrutinee, replacements);
            var alternatives: Rebuilt(core.Case.Alternative) = .{ .original = c.alternatives };
            for (c.alternatives, 0..) |alternative, i| {
                const body = try substitute(builder, alternative.body, replacements);
                try alternatives.set(builder, i, .{
                    .constructor = alternative.constructor,
                    .binders = alternative.binders,
                    .body = body,
                }, !same(body, alternative.body));
            }
            const default = if (c.default) |d| try substitute(builder, d, replacements) else null;
            if (alternatives.copy == null and same(scrutinee, c.scrutinee) and sameOptional(default, c.default)) return t;
            return try builder.caseWithDefault(scrutinee, alternatives.copy orelse c.alternatives, default, t.span);
        },
        .let => |l| {
            const value = try substitute(builder, l.value, replacements);
            const body = try substitute(builder, l.body, replacements);
            if (same(value, l.value) and same(body, l.body)) return t;
            return try builder.let(l.name, value, body, t.span);
        },
        .letrec => |l| {
            var bindings: Rebuilt(core.Letrec.Binding) = .{ .original = l.bindings };
            for (l.bindings, 0..) |binding, i| {
                const value = try substitute(builder, binding.value, replacements);
                try bindings.set(builder, i, .{ .name = binding.name, .value = value }, !same(value, binding.value));
            }
            const body = try substitute(builder, l.body, replacements);
            if (bindings.copy == null and same(body, l.body)) return t;
            return try builder.letrec(bindings.copy orelse l.bindings, body, t.span);
        },
    }
}

/// Whether `a` and `b` are one node, or one symbol or literal.
pub fn same(a: core.Term, b: core.Term) bool {
    return std.meta.eql(a.kind, b.kind);
}

/// Whether `a` and `b` are both absent, or `same`.
pub fn sameOptional(a: ?core.Term, b: ?core.Term) bool {
    if (a == null or b == null) return a == null and b == null;
    return same(a.?, b.?);
}

/// `symbol = \d -> case d of { constructor f_0 .. f_n -> f_index }`.
fn field(
    builder: core.Builder,
    env: *core.env.Env,
    symbol: core.SymbolId,
    constructor: core.SymbolId,
    count: usize,
    index: usize,
    span: diagnostic.Span,
) Allocator.Error!core.Definition {
    const dictionary = try env.interner.fresh("d");
    const binders = try builder.slice(core.SymbolId, count);
    for (binders, 0..) |*binder, i| binder.* = try env.interner.fresh(if (i == index) "m" else "_");
    const alternatives = try builder.dupeSlice(core.Case.Alternative, &.{.{
        .constructor = constructor,
        .binders = binders,
        .body = builder.symbol(binders[index], span),
    }});
    return .{
        .symbol = symbol,
        .body = try builder.lambda(dictionary, try builder.case(builder.symbol(dictionary, span), alternatives, span), span),
        .span = span,
    };
}
