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
const datatypes = core.datatypes;
const types = core.types;
const ModuleScope = @import("scope.zig").ModuleScope;

const Allocator = std.mem.Allocator;

/// The type names every signature may use without declaring them. `Range` and
/// `Point` are aliases of record types.
pub const builtin_names = [_]struct { name: []const u8, type: types.Type }{
    .{ .name = "Int", .type = types.int_type },
    .{ .name = "String", .type = types.string_type },
    .{ .name = "Regex", .type = types.regex_type },
    .{ .name = "Node", .type = types.node_type },
    .{ .name = "Kind", .type = types.kind_type },
    .{ .name = "Range", .type = types.range_type },
    .{ .name = "Point", .type = types.point_type },
};

pub fn builtinNamed(name: []const u8) ?types.Type {
    for (builtin_names) |row| {
        if (std.mem.eql(u8, row.name, name)) return row.type;
    }
    return null;
}

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
    var vars: std.ArrayList(Translator.Variable) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .scope = scope,
        .sink = sink,
    };
    const translated = try t.type(signature.type);
    const context = try arena.alloc(types.TypeClassConstraint, signature.context.len);
    for (signature.context, context) |c, *slot| slot.* = try t.constraint(c);

    return .{
        .quantified = @intCast(vars.items.len),
        .constraints = context,
        .type = translated,
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
    };
    // Parameter `i` is variable `i` in the body.
    for (alias.parameters, 0..) |parameter, i| {
        if (try t.binder(parameter, null, alias.span) == i) continue;
        try sink.report(
            .duplicate_definition,
            alias.span,
            "`{s}` names two parameters of `{s}`",
            .{ parameter, alias.name },
        );
        return error.BadAnnotation;
    }
    const body = try t.type(alias.type);

    if (vars.items.len > alias.parameters.len) {
        try sink.report(
            .unresolved_name,
            alias.type.span,
            "`{s}` is not a parameter of `{s}`",
            .{ vars.items[alias.parameters.len].name, alias.name },
        );
        return error.BadAnnotation;
    }
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

const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    vars: *std.ArrayList(Variable),
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,

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
            },
            .failed => |failure| {
                try self.scope.reportFailure(self.sink, span, name, failure);
                return error.BadAnnotation;
            },
            .missing => {},
        }
        if (builtinNamed(name)) |t| return t;
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

    /// Preconditions:
    /// - The signature's type is already translated, so every variable it
    ///   binds has its `forall` position.
    fn constraint(self: *Translator, c: cst.ClassConstraint) Error!types.TypeClassConstraint {
        const class = std.meta.stringToEnum(types.TypeClassConstraint.Class, c.class) orelse {
            try self.sink.report(.unresolved_name, c.span, "`{s}` is not a class", .{c.class});
            return error.BadAnnotation;
        };
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
