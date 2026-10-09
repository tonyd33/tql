//! `cst.Type` -> `types.Scheme`.
//!
//! Translated at desugaring rather than at type checking, because the CST is
//! freed once desugaring finishes and a signature must outlive it. What the
//! type checker receives is a finished `Scheme` in a side table.
//!
//! The translation is syntax-directed: `Filter a b` expands to `a -> [b]`, and
//! type variables become `forall` binders in order of first appearance. A
//! variable after `|` in a record type is a row, and may not also be a type.
//! An alias expands where it is written, keeping its name for printing.

const std = @import("std");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;
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

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    if (method_of) |m| _ = try t.binder(m.parameter, .type, signature.span);
    const translated = try t.type(signature.type);

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
        .quantified = @intCast(vars.items.len),
        .constraints = context,
        .type = translated,
    };
}

/// Whether bound variable `index` appears in `t`.
fn mentions(t: types.Type, index: types.TypeVar) bool {
    return switch (t) {
        .variable => |v| v == index,
        .meta, .primitive => false,
        .constructor => |c| for (c.arguments) |argument| {
            if (mentions(argument, index)) break true;
        } else false,
        .record => |r| for (r.fields) |f| {
            if (mentions(f.type.*, index)) break true;
        } else if (r.rest) |rest| mentions(rest.*, index) else false,
        .function => |arrow| mentions(arrow.from, index) or mentions(arrow.to, index),
        .alias => |a| mentions(a.expansion, index),
    };
}

/// An instance's head and context, translated.
pub const InstanceHead = struct {
    head: classes.Head,
    /// The head over its variables, bound in order from 0.
    type: types.Type,
    context: []const types.TypeClassConstraint,
};

/// Translates an instance's head and context. The head is a primitive, or a
/// declared type applied to distinct variables.
pub fn translateInstance(
    arena: Allocator,
    gpa: Allocator,
    declared: *const cst.InstanceDeclaration,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!InstanceHead {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    const head_type = try t.type(declared.head);
    const written = unparenthesized(declared.head);
    const head: classes.Head = switch (head_type) {
        .primitive => |p| .{ .primitive = p },
        .constructor => |c| blk: {
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
            break :blk .{ .datatype = c.name };
        },
        .variable => return badHead(sink, written.span, "a type variable"),
        .function => return badHead(sink, written.span, "a function type"),
        .record => return badHead(sink, written.span, "a record type"),
        .alias => return badHead(sink, written.span, "an alias"),
        .meta => unreachable,
    };

    const context = try arena.alloc(types.TypeClassConstraint, declared.context.len);
    for (declared.context, context) |c, *slot| slot.* = try t.constraint(c);
    return .{ .head = head, .type = head_type, .context = context };
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
        "an instance head must be a primitive or a declared type, not {s}",
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
    if (scheme.quantified == std.math.maxInt(types.TypeVar)) {
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

    const result = types.variable_type(scheme.quantified);
    const continuation = try types.arrows(arena, holes, result);
    return .{
        .quantified = scheme.quantified + 1,
        .type = try types.func(arena, matched, try types.func(arena, continuation, try types.func(arena, result, result))),
    };
}

/// Translates an alias declaration's body, numbering its variables by
/// parameter position.
///
/// Preconditions:
/// - Every alias the body names is already declared.
pub fn translateAlias(
    arena: Allocator,
    gpa: Allocator,
    alias: *const cst.TypeAlias,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!datatypes.Alias {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
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
    try t.declaration(alias.name, alias.parameters, alias.span);
    const body = try t.type(alias.type);

    const parameters = try arena.alloc(datatypes.Alias.Parameter, alias.parameters.len);
    for (vars.items, parameters) |v, *slot| {
        const sort = v.sort orelse {
            try sink.report(
                .type_mismatch,
                alias.span,
                "`{s}` is a parameter of `{s}` that its body never uses",
                .{ v.name, alias.name },
            );
            return error.BadAnnotation;
        };
        slot.* = .{ .name = try arena.dupe(u8, v.name), .sort = sort };
    }

    return .{
        .name = try arena.dupe(u8, alias.name),
        .parameters = parameters,
        .body = body,
    };
}

/// Translates a constructor field's written type. Variable `i` is the
/// datatype's parameter `i`.
pub fn translateField(
    arena: Allocator,
    gpa: Allocator,
    written: cst.Type,
    declared: *const cst.DataDeclaration,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
) Error!types.Type {
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .scope = scope,
        .sink = sink,
        .variables = .free,
    };
    try t.declaration(declared.name, declared.parameters, declared.span);
    const field = try t.type(written);
    if (hasRecord(field)) {
        try sink.report(.type_mismatch, written.span, "a constructor field may not be a record yet", .{});
        return error.BadAnnotation;
    }
    return field;
}

/// Whether a record appears anywhere in `t`.
fn hasRecord(t: types.Type) bool {
    return switch (t) {
        .variable, .meta, .primitive => false,
        .record => true,
        .constructor => |c| for (c.arguments) |argument| {
            if (hasRecord(argument)) break true;
        } else false,
        .function => |arrow| hasRecord(arrow.from) or hasRecord(arrow.to),
        .alias => |a| hasRecord(a.expansion),
    };
}

const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    vars: *std.ArrayList(Variable),
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
    variables: union(enum) {
        /// Each new variable becomes a `forall` binder.
        free,
        /// Only the parameters of the named declaration are in scope.
        parameters_of: []const u8,
    },

    /// Bring `parameters` into scope as variables `0..` and admit no others.
    fn declaration(self: *Translator, name: []const u8, parameters: []const []const u8, span: diagnostic.Span) Error!void {
        for (parameters) |parameter| _ = try self.binder(parameter, null, span);
        self.variables = .{ .parameters_of = name };
    }

    fn @"type"(self: *Translator, node: cst.Type) Error!types.Type {
        return switch (node.kind) {
            .constructor => |name| try self.named(name, node.span),
            .application => |a| try self.application(a.*, node.span),
            .variable => |name| .{ .variable = try self.binder(name, .type, node.span) },
            .list => |element| try self.scope.datatypes.list(self.arena, try self.type(element.*)),
            .parenthesized => |inner| try self.type(inner.*),
            .function => |f| try types.func(self.arena, try self.type(f.from), try self.type(f.to)),
            // `Filter a b` is `a -> [b]`. The expansion happens here, so
            // nothing downstream has a `Filter` case.
            .filter => |f| try types.func(
                self.arena,
                try self.type(f.input),
                try self.scope.datatypes.list(self.arena, try self.type(f.output)),
            ),
            .record => |r| try self.record(r, node.span),
        };
    }

    fn named(self: *Translator, name: []const u8, span: diagnostic.Span) Error!types.Type {
        switch (self.scope.typeNamed(name)) {
            .found => |found| switch (found) {
                .datatype => |declared| {
                    const parameters = self.scope.datatypes.get(declared).parameters;
                    if (parameters != 0) {
                        try self.sink.report(
                            .type_mismatch,
                            span,
                            "`{s}` takes {d} type argument(s), given 0",
                            .{ name, parameters },
                        );
                        return error.BadAnnotation;
                    }
                    return try types.constructed(self.arena, declared, self.scope.datatypes.get(declared).name, &.{});
                },
                .alias => |alias| return try self.aliasAt(alias, &.{}, span),
                .primitive => |p| return .{ .primitive = p },
                .class => return try self.notAType(name, span),
            },
            .failed => |failure| {
                try self.scope.reportFailure(self.sink, span, name, failure);
                return error.BadAnnotation;
            },
            .missing => {},
        }
        try self.sink.report(.unresolved_name, span, "`{s}` is not a type", .{name});
        return error.BadAnnotation;
    }

    fn application(
        self: *Translator,
        node: cst.TypeApplication,
        span: diagnostic.Span,
    ) Error!types.Type {
        const declared = switch (self.scope.typeNamed(node.constructor)) {
            .found => |found| switch (found) {
                .datatype => |declared| declared,
                .alias => |alias| return try self.aliasAt(alias, node.arguments, span),
                .primitive => {
                    try self.sink.report(
                        .type_mismatch,
                        span,
                        "`{s}` takes 0 type argument(s), given {d}",
                        .{ node.constructor, node.arguments.len },
                    );
                    return error.BadAnnotation;
                },
                .class => return try self.notAType(node.constructor, span),
            },
            .failed => |failure| {
                try self.scope.reportFailure(self.sink, span, node.constructor, failure);
                return error.BadAnnotation;
            },
            .missing => {
                try self.sink.report(.unresolved_name, span, "`{s}` is not a type", .{node.constructor});
                return error.BadAnnotation;
            },
        };
        const parameters = self.scope.datatypes.get(declared).parameters;
        if (node.arguments.len != parameters) {
            try self.sink.report(
                .type_mismatch,
                span,
                "`{s}` takes {d} type argument(s), given {d}",
                .{ node.constructor, parameters, node.arguments.len },
            );
            return error.BadAnnotation;
        }
        const arguments = try self.arena.alloc(types.Type, node.arguments.len);
        for (node.arguments, arguments) |argument, *copy| copy.* = try self.type(argument);
        return try types.constructed(self.arena, declared, self.scope.datatypes.get(declared).name, arguments);
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

    const Sort = datatypes.Alias.Sort;

    /// `alias` applied to `written`, expanded.
    fn aliasAt(
        self: *Translator,
        alias: *const datatypes.Alias,
        written: []const cst.Type,
        span: diagnostic.Span,
    ) Error!types.Type {
        if (written.len != alias.parameters.len) {
            try self.sink.report(
                .type_mismatch,
                span,
                "`{s}` takes {d} type argument(s), given {d}",
                .{ alias.name, alias.parameters.len, written.len },
            );
            return error.BadAnnotation;
        }
        const arguments = try self.arena.alloc(types.Type, written.len);
        for (alias.parameters, written, arguments) |parameter, argument, *slot| {
            slot.* = switch (parameter.sort) {
                .type => try self.type(argument),
                .row => try self.row(argument, alias, parameter),
            };
        }
        return try alias.apply(self.arena, arguments);
    }

    /// The argument for a row parameter, which only a type variable can be.
    fn row(
        self: *Translator,
        argument: cst.Type,
        alias: *const datatypes.Alias,
        parameter: datatypes.Alias.Parameter,
    ) Error!types.Type {
        var inner = argument;
        while (inner.kind == .parenthesized) inner = inner.kind.parenthesized.*;
        if (inner.kind != .variable) {
            try self.sink.report(
                .type_mismatch,
                argument.span,
                "`{s}` in `{s}` stands for a record's other fields, so its argument must be a type variable",
                .{ parameter.name, alias.name },
            );
            return error.BadAnnotation;
        }
        return .{ .variable = try self.binder(inner.kind.variable, .row, argument.span) };
    }

    const Variable = struct {
        name: []const u8,
        /// Null for an alias parameter its body has not used yet.
        sort: ?Sort,
    };

    /// The `forall` position of a type variable, assigned on first appearance.
    fn binder(self: *Translator, name: []const u8, sort: ?Sort, span: diagnostic.Span) Error!types.TypeVar {
        for (self.vars.items, 0..) |*seen, i| {
            if (!std.mem.eql(u8, seen.name, name)) continue;
            const known = seen.sort orelse {
                seen.sort = sort;
                return @intCast(i);
            };
            if (sort != null and known != sort.?) {
                try self.sink.report(
                    .type_mismatch,
                    span,
                    "`{s}` stands for a record's other fields in one place and for a type in another",
                    .{name},
                );
                return error.BadAnnotation;
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
        try self.vars.append(self.gpa, .{ .name = name, .sort = sort });
        return @intCast(self.vars.items.len - 1);
    }

    fn record(self: *Translator, r: cst.RecordType, span: diagnostic.Span) Error!types.Type {
        const copies = try self.arena.alloc(types.Type.Field, r.fields.len);
        for (r.fields, copies) |f, *copy| {
            copy.* = .{
                .label = try self.arena.dupe(u8, f.name),
                .type = try types.store(self.arena, try self.type(f.type)),
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
