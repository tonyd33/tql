//! `cst.Type` -> `types.Scheme`.
//!
//! Translated at desugaring rather than at type checking, because the CST is
//! freed once desugaring finishes and a signature must outlive it. What the
//! type checker receives is a finished `Scheme` in a side table.
//!
//! The translation is syntax-directed: `Filter a b` expands to `a -> [b]`, and
//! type variables become `forall` binders in order of first appearance.

const std = @import("std");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

pub const primitive_names = [_]struct { name: []const u8, type: types.Type }{
    .{ .name = "Int", .type = types.int_type },
    .{ .name = "String", .type = types.string_type },
    .{ .name = "Regex", .type = types.regex_type },
    .{ .name = "Node", .type = types.node_type },
    .{ .name = "Range", .type = types.range_type },
    .{ .name = "Kind", .type = types.kind_type },
};

pub fn primitiveNamed(name: []const u8) ?types.Type {
    for (primitive_names) |row| {
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
    declared: *const datatypes.Registry,
    sink: *diagnostic.Sink,
) Error!types.Scheme {
    var vars: std.ArrayList([]const u8) = .empty;
    defer vars.deinit(gpa);

    var t = Translator{
        .arena = arena,
        .gpa = gpa,
        .vars = &vars,
        .datatypes = declared,
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

const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    vars: *std.ArrayList([]const u8),
    datatypes: *const datatypes.Registry,
    sink: *diagnostic.Sink,

    fn @"type"(self: *Translator, node: cst.Type) Error!types.Type {
        return switch (node.kind) {
            .constructor => |name| try self.named(name, node.span),
            .application => |a| try self.application(a.*, node.span),
            .variable => |name| .{ .variable = try self.binder(name, node.span) },
            .list => |element| try self.datatypes.list(self.arena, try self.type(element.*)),
            .parenthesized => |inner| try self.type(inner.*),
            .function => |f| try types.func(self.arena, try self.type(f.from), try self.type(f.to)),
            // `Filter a b` is `a -> [b]`. The expansion happens here, so
            // nothing downstream has a `Filter` case.
            .filter => |f| try types.func(
                self.arena,
                try self.type(f.input),
                try self.datatypes.list(self.arena, try self.type(f.output)),
            ),
            .record => |fields| try self.record(fields),
        };
    }

    fn named(self: *Translator, name: []const u8, span: diagnostic.Span) Error!types.Type {
        if (self.datatypes.lookup(name)) |declared| {
            const parameters = self.datatypes.get(declared).parameters;
            if (parameters != 0) {
                try self.sink.report(
                    .type_mismatch,
                    span,
                    "`{s}` takes {d} type argument(s), given 0",
                    .{ name, parameters },
                );
                return error.BadAnnotation;
            }
            return try types.constructed(self.arena, declared, self.datatypes.get(declared).name, &.{});
        }
        if (primitiveNamed(name)) |t| return t;
        try self.sink.report(.unresolved_name, span, "`{s}` is not a type", .{name});
        return error.BadAnnotation;
    }

    fn application(
        self: *Translator,
        node: cst.TypeApplication,
        span: diagnostic.Span,
    ) Error!types.Type {
        const declared = self.datatypes.lookup(node.constructor) orelse {
            try self.sink.report(.unresolved_name, span, "`{s}` is not a type", .{node.constructor});
            return error.BadAnnotation;
        };
        const parameters = self.datatypes.get(declared).parameters;
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
        return try types.constructed(self.arena, declared, self.datatypes.get(declared).name, arguments);
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
            if (std.mem.eql(u8, seen, c.variable)) {
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

    /// The `forall` position of a type variable, assigned on first appearance.
    fn binder(self: *Translator, name: []const u8, span: diagnostic.Span) Error!types.TypeVar {
        for (self.vars.items, 0..) |seen, i| {
            if (std.mem.eql(u8, seen, name)) return @intCast(i);
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
        try self.vars.append(self.gpa, name);
        return @intCast(self.vars.items.len - 1);
    }

    fn record(self: *Translator, fields: []const cst.TypeField) Error!types.Type {
        const copies = try self.arena.alloc(types.Type.Field, fields.len);
        for (fields, copies) |f, *copy| {
            copy.* = .{
                .label = try self.arena.dupe(u8, f.name),
                .type = try types.store(self.arena, try self.type(f.type)),
            };
        }
        return .{ .record = copies };
    }
};
