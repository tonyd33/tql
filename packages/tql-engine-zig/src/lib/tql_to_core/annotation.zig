//! `cst.Type` -> `types.Scheme`.
//!
//! Translated at desugaring rather than at type checking, because the CST is
//! freed once desugaring finishes and a signature must outlive it. What the
//! type checker receives is a finished `Scheme` in a side table.
//!
//! The translation is syntax-directed: `Filter a b` expands to `a -> [b]`, and
//! type variables become `forall` binders in order of first appearance. Each
//! written type is checked against the kind its position expects: a variable
//! after `|` in a record type has kind `Row`, and may not also have kind
//! `Type`.
//! An alias expands where it is written, keeping its name for printing.

const std = @import("std");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;
const kinds = @import("kinds.zig");
const scope_mod = @import("scope.zig");
const ModuleScope = scope_mod.ModuleScope;

const Allocator = std.mem.Allocator;

pub const Error = error{BadAnnotation} || Allocator.Error;

/// Translates a signature's written type into a scheme.
///
/// Type variables are collected in order of first appearance and become the
/// quantified binders, so `Filter a a` is `forall a. a -> [a]`.
pub fn translate(
    arena: Allocator,
    gpa: Allocator,
    signature: *const cst.Signature,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Scheme {
    return translateSignature(arena, gpa, signature, null, scope, sink);
}

/// The class `written` names in `scope`. Reports a name that is not one.
pub fn resolveClass(
    scope: *const ModuleScope,
    written: []const u8,
    span: diagnostic.Span,
    sink: *diagnostic.Sink,
) Error!classes.ClassId {
    switch (scope.typeNamed(written)) {
        .found => |found| switch (found) {
            .class => |id| return id,
            else => {},
        },
        .failed => |failure| {
            try scope.reportFailure(sink, span, written, failure);
            return error.BadAnnotation;
        },
        .missing => {},
    }
    try sink.report(.unresolved_name, span, "`{s}` is not a class", .{written});
    return error.BadAnnotation;
}

/// The class a method signature belongs to.
pub const MethodOf = struct {
    class: classes.ClassId,
    name: []const u8,
    /// The class parameter as written.
    parameter: []const u8,
    /// The class parameter's kind.
    kind: types.Kind,
};

/// Translates the signature of a method of `class` into the method's scheme:
/// the class parameter is variable 0, and `class a` heads the context.
pub fn translateMethod(
    arena: Allocator,
    gpa: Allocator,
    signature: *const cst.Signature,
    class: MethodOf,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Scheme {
    return translateSignature(arena, gpa, signature, class, scope, sink);
}

fn translateSignature(
    arena: Allocator,
    gpa: Allocator,
    signature: *const cst.Signature,
    method_of: ?MethodOf,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Scheme {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var inference = kinds.Inference.init(arena, gpa);
    defer inference.deinit();
    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .kinds = &inference,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    if (method_of) |m| _ = try t.binder(m.parameter, m.kind, signature.span);
    const translated = try t.type(signature.type, .type);

    const leading: usize = if (method_of != null) 1 else 0;
    const context = try arena.alloc(types.TypeClassConstraint, leading + signature.context.len);
    if (method_of) |m| {
        if (!mentions(translated, 0)) {
            try sink.report(
                .invalid_class,
                signature.span,
                "`{s}` does not mention `{s}`, the parameter of `{s}`",
                .{ signature.name, m.parameter, m.name },
            );
            return error.BadAnnotation;
        }
        context[0] = .{ .class = m.class, .type = types.variable_type(0) };
    }
    for (signature.context, context[leading..]) |c, *slot| {
        if (method_of) |m| if (std.mem.eql(u8, c.variable, m.parameter)) {
            try sink.report(
                .invalid_class,
                c.span,
                "`{s}` constrains `{s}`, the parameter of `{s}`",
                .{ signature.name, m.parameter, m.name },
            );
            return error.BadAnnotation;
        };
        slot.* = try t.constraint(c);
    }

    return .{
        .variables = try t.variableKinds(),
        .constraints = context,
        .type = translated,
    };
}

/// Whether bound variable `index` appears in `t`.
fn mentions(t: types.Type, index: types.TypeVar) bool {
    return switch (t) {
        .variable => |v| v == index,
        .meta => false,
        .constructor => |c| for (c.arguments) |argument| {
            if (mentions(argument, index)) break true;
        } else false,
        .record => |r| for (r.fields) |f| {
            if (mentions(f.type.*, index)) break true;
        } else if (r.rest) |rest| mentions(rest.*, index) else false,
        .function => |arrow| mentions(arrow.from, index) or mentions(arrow.to, index),
        .alias => |a| mentions(a.expansion, index),
        .application => |a| mentions(a.head, index) or mentions(a.argument, index),
    };
}

/// An instance's head and context, translated.
pub const InstanceHead = struct {
    /// A datatype over distinct variables, bound in order from 0.
    type: types.Type,
    context: []const types.TypeClassConstraint,

    /// Returns the datatype the instance is declared at.
    pub fn head(self: InstanceHead) core.datatypes.TypeId {
        return self.type.constructor.name;
    }
};

/// Translates an instance's head and context. The head is a declared type
/// applied to distinct variables, of kind `parameter`.
pub fn translateInstance(
    arena: Allocator,
    gpa: Allocator,
    declared: *const cst.InstanceDeclaration,
    parameter: types.Kind,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!InstanceHead {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var inference = kinds.Inference.init(arena, gpa);
    defer inference.deinit();
    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .kinds = &inference,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    const head_type = try t.type(declared.head, parameter);
    const written = unparenthesized(declared.head);
    switch (head_type) {
        .constructor => |c| {
            for (c.arguments, headArguments(written), 0..) |argument, w, i| {
                if (argument != .variable) {
                    try sink.report(
                        .invalid_instance,
                        w.span,
                        "each argument of an instance head must be a type variable",
                        .{},
                    );
                    return error.BadAnnotation;
                }
                // Variables are numbered by first appearance, so a lower
                // number is a repeat.
                if (argument.variable != i) {
                    try sink.report(
                        .invalid_instance,
                        w.span,
                        "`{s}` appears more than once in an instance head",
                        .{vars.items[argument.variable].name},
                    );
                    return error.BadAnnotation;
                }
            }
        },
        .variable, .application => return badHead(sink, written.span, "a type variable"),
        .function => return badHead(sink, written.span, "a function type"),
        .record => return badHead(sink, written.span, "a record type"),
        .alias => return badHead(sink, written.span, "an alias"),
        .meta => unreachable,
    }

    const context = try arena.alloc(types.TypeClassConstraint, declared.context.len);
    for (declared.context, context) |c, *slot| slot.* = try t.constraint(c);
    return .{ .type = head_type, .context = context };
}

fn unparenthesized(written: cst.Type) cst.Type {
    var inner = written;
    while (inner.kind == .parenthesized) inner = inner.kind.parenthesized.*;
    return inner;
}

/// The written arguments of an unparenthesized head the translator took for
/// a declared type.
fn headArguments(written: cst.Type) []const cst.Type {
    return switch (written.kind) {
        .application => |a| a.arguments,
        .list => |element| element[0..1],
        else => &.{},
    };
}

fn badHead(sink: *diagnostic.Sink, span: diagnostic.Span, what: []const u8) Error!InstanceHead {
    try sink.report(
        .invalid_instance,
        span,
        "an instance head must be a declared type, not {s}",
        .{what},
    );
    return error.BadAnnotation;
}

/// Translates a pattern synonym's signature `P :: T_1 -> .. -> T_n -> T` into
/// its matcher's scheme, `forall r. T -> (T_1 -> .. -> T_n -> r) -> r -> r`.
pub fn translateSynonym(
    arena: Allocator,
    gpa: Allocator,
    signature: *const cst.PatternSignature,
    arity: u32,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Scheme {
    const written: cst.Signature = .{ .name = signature.name, .type = signature.type, .span = signature.span };
    const scheme = try translate(arena, gpa, &written, scope, sink);
    if (scheme.variables.len == std.math.maxInt(types.TypeVar)) {
        try sink.report(
            .limit,
            signature.span,
            "a signature has more than {d} type variables",
            .{std.math.maxInt(types.TypeVar) - 1},
        );
        return error.BadAnnotation;
    }

    const holes = try gpa.alloc(types.Type, arity);
    defer gpa.free(holes);
    var matched = scheme.type;
    for (holes, 0..) |*hole, i| {
        const arrow = types.arrowOf(matched) orelse {
            try sink.report(
                .signature_mismatch,
                signature.span,
                "`{s}` takes {d} argument(s), but its signature gives {d}",
                .{ signature.name, arity, i },
            );
            return error.BadAnnotation;
        };
        hole.* = arrow.from;
        matched = arrow.to;
    }

    const result = types.variable_type(@intCast(scheme.variables.len));
    const continuation = try types.arrows(arena, holes, result);
    return .{
        .variables = try std.mem.concat(arena, types.Kind, &.{ scheme.variables, &.{.type} }),
        .type = try types.func(arena, matched, try types.func(arena, continuation, try types.func(arena, result, result))),
    };
}

/// Translates an alias declaration's body, numbering its variables by
/// parameter position. Its parameters' kinds and its own are left to
/// `group` to solve.
///
/// Preconditions:
/// - Every alias the body names is already declared.
pub fn translateAlias(
    arena: Allocator,
    gpa: Allocator,
    alias: *const cst.TypeAlias,
    group: *kinds.Group,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!datatypes.Alias {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .kinds = &group.inference,
        .group = group,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    for (alias.parameters, 0..) |parameter, i| {
        for (alias.parameters[0..i]) |earlier| {
            if (!std.mem.eql(u8, earlier, parameter)) continue;
            try sink.report(
                .duplicate_definition,
                alias.span,
                "`{s}` names two parameters of `{s}`",
                .{ parameter, alias.name },
            );
            return error.BadAnnotation;
        }
    }
    try t.declaration(alias.name, alias.parameters, null, alias.span);
    const kind = try group.inference.fresh();
    const body = try t.type(alias.type, kind);

    const parameters = try arena.alloc(datatypes.Alias.Parameter, alias.parameters.len);
    for (vars.items, parameters) |v, *slot| slot.* = .{ .name = try arena.dupe(u8, v.name), .kind = v.kind };

    return .{
        .name = try arena.dupe(u8, alias.name),
        .parameters = parameters,
        .body = body,
        .kind = kind,
    };
}

/// Translates the written type of a field of datatype `id`. Variable `i` is the
/// datatype's parameter `i`, of the kind `group` infers for it.
pub fn translateField(
    arena: Allocator,
    gpa: Allocator,
    written: cst.Type,
    declared: *const cst.DataDeclaration,
    id: datatypes.TypeId,
    group: *kinds.Group,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Type {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .kinds = &group.inference,
        .group = group,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    try t.declaration(declared.name, declared.parameters, t.parameterKinds(id), declared.span);
    const field = try t.type(written, .type);
    if (hasRecord(field)) {
        try sink.report(.type_mismatch, written.span, "a constructor field may not be a record yet", .{});
        return error.BadAnnotation;
    }
    return field;
}

/// Whether a record appears anywhere in `t`.
fn hasRecord(t: types.Type) bool {
    return switch (t) {
        .variable, .meta => false,
        .record => true,
        .constructor => |c| for (c.arguments) |argument| {
            if (hasRecord(argument)) break true;
        } else false,
        .function => |arrow| hasRecord(arrow.from) or hasRecord(arrow.to),
        .alias => |a| hasRecord(a.expansion),
        .application => |a| hasRecord(a.head) or hasRecord(a.argument),
    };
}

const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    vars: *std.ArrayList(Variable),
    kinds: *kinds.Inference,
    /// The module's own declarations, while their kinds are inferred.
    group: ?*const kinds.Group = null,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
    variables: union(enum) {
        /// Each new variable becomes a `forall` binder.
        free,
        /// Only the parameters of the named declaration are in scope.
        parameters_of: []const u8,
    },

    /// Bring `parameters` into scope as variables `0..` and admit no others.
    /// Each has kind `parameter_kinds[i]`, or a kind its uses decide when
    /// `parameter_kinds` is null.
    fn declaration(
        self: *Translator,
        name: []const u8,
        parameters: []const []const u8,
        parameter_kinds: ?[]const types.Kind,
        span: diagnostic.Span,
    ) Error!void {
        for (parameters, 0..) |parameter, i| {
            _ = try self.binder(parameter, if (parameter_kinds) |k| k[i] else null, span);
        }
        self.variables = .{ .parameters_of = name };
    }

    /// Each variable's kind, defaulting to `Type` where its uses left it
    /// open.
    fn variableKinds(self: *const Translator) Error![]const types.Kind {
        const out = try self.arena.alloc(types.Kind, self.vars.items.len);
        for (self.vars.items, out) |v, *slot| slot.* = try self.kinds.zonk(v.kind, .type);
        return out;
    }

    /// Translates `node`, which must have kind `expected`.
    fn @"type"(self: *Translator, node: cst.Type, expected: types.Kind) Error!types.Type {
        switch (node.kind) {
            .constructor => |name| return try self.named(name, &.{}, node.span, expected),
            .application => |a| switch (a.head) {
                .constructor => |name| return try self.named(name, a.arguments, node.span, expected),
                .variable => |name| return try self.variable(name, a.arguments, node.span, expected),
            },
            .variable => |name| return try self.variable(name, &.{}, node.span, expected),
            .parenthesized => |inner| return try self.type(inner.*, expected),
            .list, .function, .filter, .record => {},
        }
        if (!self.kinds.unify(expected, .type)) {
            const what = switch (node.kind) {
                .list => "a list type",
                .function => "a function type",
                .filter => "a `Filter` type",
                .record => "a record type",
                .constructor, .application, .variable, .parenthesized => unreachable,
            };
            return self.kindMismatch(node.span, what, .type, expected);
        }
        return switch (node.kind) {
            .list => |element| try self.scope.datatypes.list(self.arena, try self.type(element.*, .type)),
            .function => |f| try types.func(self.arena, try self.type(f.from, .type), try self.type(f.to, .type)),
            // `Filter a b` is `a -> [b]`. The expansion happens here, so
            // nothing downstream has a `Filter` case.
            .filter => |f| try types.func(
                self.arena,
                try self.type(f.input, .type),
                try self.scope.datatypes.list(self.arena, try self.type(f.output, .type)),
            ),
            .record => |r| try self.record(r, node.span),
            .constructor, .application, .variable, .parenthesized => unreachable,
        };
    }

    /// The type `name` names, applied to `written`, which must have kind
    /// `expected`.
    fn named(
        self: *Translator,
        name: []const u8,
        written: []const cst.Type,
        span: diagnostic.Span,
        expected: types.Kind,
    ) Error!types.Type {
        // The module's own declarations resolve first, as in scope.
        if (self.group) |g| if (g.aliases.get(name)) |alias| return try self.aliased(alias, written, span, expected);
        switch (self.scope.typeNamed(name)) {
            .found => |found| switch (found) {
                .datatype => |id| return try self.spine(name, .{ .datatype = id }, written, span, expected),
                .alias => |alias| return try self.aliased(alias, written, span, expected),
                .class => return try self.notAType(name, span),
            },
            .failed => |failure| {
                try self.scope.reportFailure(self.sink, span, name, failure);
                return error.BadAnnotation;
            },
            .missing => {
                try self.sink.report(.unresolved_name, span, "`{s}` is not a type", .{name});
                return error.BadAnnotation;
            },
        }
    }

    /// `alias` applied to `written`, which must have kind `expected`.
    fn aliased(
        self: *Translator,
        alias: *const datatypes.Alias,
        written: []const cst.Type,
        span: diagnostic.Span,
        expected: types.Kind,
    ) Error!types.Type {
        if (written.len < alias.parameters.len) {
            try self.sink.report(
                .type_mismatch,
                span,
                "`{s}` takes {d} type argument(s), given {d}",
                .{ alias.name, alias.parameters.len, written.len },
            );
            return error.BadAnnotation;
        }
        return try self.spine(alias.name, .{ .alias = alias }, written, span, expected);
    }

    /// Type variable `name` applied to `written`, which must have kind
    /// `expected`.
    fn variable(
        self: *Translator,
        name: []const u8,
        written: []const cst.Type,
        span: diagnostic.Span,
        expected: types.Kind,
    ) Error!types.Type {
        return try self.spine(name, .{ .variable = try self.binder(name, null, span) }, written, span, expected);
    }

    const Head = union(enum) {
        datatype: datatypes.TypeId,
        /// Given at least one argument per parameter.
        alias: *const datatypes.Alias,
        variable: types.TypeVar,
    };

    /// `head`, written `name`, applied to `written`, which must have kind
    /// `expected`.
    fn spine(
        self: *Translator,
        name: []const u8,
        head: Head,
        written: []const cst.Type,
        span: diagnostic.Span,
        expected: types.Kind,
    ) Error!types.Type {
        // The head's kind is `parameters[0] -> .. -> result`. Build no arrows
        // for a saturated head.
        const parameters: []const types.Kind, const result: types.Kind = switch (head) {
            .datatype => |id| .{ self.parameterKinds(id), .type },
            .alias => |alias| blk: {
                const kinds_of = try self.arena.alloc(types.Kind, alias.parameters.len);
                for (alias.parameters, kinds_of) |parameter, *slot| slot.* = parameter.kind;
                break :blk .{ kinds_of, alias.kind };
            },
            .variable => |index| .{ &.{}, self.vars.items[index].kind },
        };

        const arguments = try self.arena.alloc(types.Type, written.len);
        var rest = result;
        for (written, arguments, 0..) |argument, *slot, taken| {
            const from = if (taken < parameters.len) parameters[taken] else blk: {
                const arrow = try self.arrowOf(rest) orelse {
                    var names: types.KindNames = .{};
                    const kind = try types.Kind.arrows(self.arena, parameters, result);
                    try self.sink.report(
                        .kind_mismatch,
                        span,
                        "`{s}` has kind `{f}`: it takes {d} type argument(s), given {d}",
                        .{ name, (try self.kinds.zonk(kind, null)).named(&names), taken, written.len },
                    );
                    return error.BadAnnotation;
                };
                rest = arrow.to;
                break :blk arrow.from;
            };
            slot.* = try self.type(argument, from);
        }
        if (written.len < parameters.len) rest = try types.Kind.arrows(self.arena, parameters[written.len..], rest);
        if (!self.kinds.unify(rest, expected)) {
            if (written.len == 0) return self.kindMismatch(span, try std.fmt.allocPrint(self.arena, "`{s}`", .{name}), rest, expected);
            var arity: usize = 0;
            var each = try self.kinds.zonk(try types.Kind.arrows(self.arena, parameters, result), null);
            while (each == .arrow) : (each = each.arrow.to) arity += 1;
            const subject = try std.fmt.allocPrint(self.arena, "`{s}` given {d} of its {d} type arguments", .{ name, written.len, arity });
            return self.kindMismatch(span, subject, rest, expected);
        }

        return switch (head) {
            .datatype => |id| try types.constructed(self.arena, id, self.scope.datatypes.get(id).name, arguments),
            .alias => |alias| try alias.apply(self.arena, arguments),
            .variable => |index| blk: {
                var applied: types.Type = .{ .variable = index };
                for (arguments) |argument| applied = try types.apply(self.arena, applied, argument);
                break :blk applied;
            },
        };
    }

    /// The kinds of datatype `id`'s parameters, solved or not.
    fn parameterKinds(self: *const Translator, id: datatypes.TypeId) []const types.Kind {
        if (self.group) |g| if (g.datatypes.get(id)) |parameters| return parameters;
        return self.scope.datatypes.get(id).parameters;
    }

    /// The arrow `k` is, making it one when it is unsolved. Null when it is
    /// `Type` or `Row`.
    fn arrowOf(self: *Translator, k: types.Kind) Error!?types.Kind.Arrow {
        switch (self.kinds.resolve(k)) {
            .arrow => |arrow| return arrow.*,
            .meta => {
                const made = try types.Kind.arrows(self.arena, &.{try self.kinds.fresh()}, try self.kinds.fresh());
                _ = self.kinds.unify(k, made);
                return made.arrow.*;
            },
            .type, .row => return null,
        }
    }

    /// Report that `subject` has kind `has` where kind `wanted` is expected.
    fn kindMismatch(self: *Translator, span: diagnostic.Span, subject: []const u8, has: types.Kind, wanted: types.Kind) Error {
        var names: types.KindNames = .{};
        try self.sink.report(.kind_mismatch, span, "{s} has kind `{f}`, but kind `{f}` is expected", .{
            subject,
            (try self.kinds.zonk(has, null)).named(&names),
            (try self.kinds.zonk(wanted, null)).named(&names),
        });
        return error.BadAnnotation;
    }

    fn notAType(self: *Translator, name: []const u8, span: diagnostic.Span) Error!types.Type {
        try self.sink.report(.unresolved_name, span, "`{s}` is a class, not a type", .{name});
        return error.BadAnnotation;
    }

    /// Preconditions:
    /// - The signature's type is already translated, so every variable it
    ///   binds has its `forall` position.
    fn constraint(self: *Translator, c: cst.ClassConstraint) Error!types.TypeClassConstraint {
        const class = try resolveClass(self.scope, c.class, c.span, self.sink);
        for (self.vars.items, 0..) |seen, i| {
            if (std.mem.eql(u8, seen.name, c.variable)) {
                return .{ .class = class, .type = .{ .variable = @intCast(i) } };
            }
        }
        try self.sink.report(
            .unresolved_name,
            c.span,
            "`{s}` is constrained but does not appear in the type",
            .{c.variable},
        );
        return error.BadAnnotation;
    }

    const Variable = struct {
        name: []const u8,
        kind: types.Kind,
    };

    /// The `forall` position of a type variable, assigned on first appearance.
    /// It must have kind `kind`, or any kind when `kind` is null.
    fn binder(self: *Translator, name: []const u8, kind: ?types.Kind, span: diagnostic.Span) Error!types.TypeVar {
        for (self.vars.items, 0..) |seen, i| {
            if (!std.mem.eql(u8, seen.name, name)) continue;
            const wanted = kind orelse return @intCast(i);
            if (!self.kinds.unify(seen.kind, wanted)) {
                return self.kindMismatch(span, try std.fmt.allocPrint(self.arena, "`{s}`", .{name}), seen.kind, wanted);
            }
            return @intCast(i);
        }
        switch (self.variables) {
            .free => {},
            .parameters_of => |owner| {
                try self.sink.report(.unresolved_name, span, "`{s}` is not a parameter of `{s}`", .{ name, owner });
                return error.BadAnnotation;
            },
        }
        if (self.vars.items.len == std.math.maxInt(types.TypeVar)) {
            try self.sink.report(
                .limit,
                span,
                "a signature has more than {d} type variables",
                .{std.math.maxInt(types.TypeVar)},
            );
            return error.BadAnnotation;
        }
        try self.vars.append(self.gpa, .{ .name = name, .kind = kind orelse try self.kinds.fresh() });
        return @intCast(self.vars.items.len - 1);
    }

    fn record(self: *Translator, r: cst.RecordType, span: diagnostic.Span) Error!types.Type {
        const copies = try self.arena.alloc(types.Type.Field, r.fields.len);
        for (r.fields, copies) |f, *copy| {
            copy.* = .{
                .label = try self.arena.dupe(u8, f.name),
                .type = try types.store(self.arena, try self.type(f.type, .type)),
            };
        }
        std.mem.sort(types.Type.Field, copies, {}, types.Type.Field.lessThan);
        if (copies.len > 1) for (copies[0 .. copies.len - 1], copies[1..]) |previous, f| {
            if (!std.mem.eql(u8, previous.label, f.label)) continue;
            try self.sink.report(
                .type_mismatch,
                span,
                "`{s}` labels two fields of one record",
                .{f.label},
            );
            return error.BadAnnotation;
        };
        const rest = if (r.row) |name|
            try types.store(self.arena, .{ .variable = try self.binder(name, .row, span) })
        else
            null;
        return .{ .record = .{ .fields = copies, .rest = rest } };
    }
};
