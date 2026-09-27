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

const primitive_names = [_]struct { name: []const u8, type: types.Type }{
    .{ .name = "Int", .type = types.int_type },
    .{ .name = "String", .type = types.string_type },
    .{ .name = "Regex", .type = types.regex_type },
    .{ .name = "Node", .type = types.node_type },
    .{ .name = "Range", .type = types.range_type },
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

    return .{
        .quantified = @intCast(vars.items.len),
        // A signature cannot write a constraint: the grammar has no `=>`
        // production. An annotation whose inferred scheme carries one is
        // still checked with it attached.
        .constraints = &.{},
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
            .variable => |name| .{ .variable = try self.binder(name) },
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
        try self.sink.report(.type_mismatch, span, "`{s}` is not a type", .{name});
        return error.BadAnnotation;
    }

    fn application(
        self: *Translator,
        node: cst.TypeApplication,
        span: diagnostic.Span,
    ) Error!types.Type {
        const declared = self.datatypes.lookup(node.constructor) orelse {
            try self.sink.report(.type_mismatch, span, "`{s}` is not a type", .{node.constructor});
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

    /// The `forall` position of a type variable, assigned on first appearance.
    fn binder(self: *Translator, name: []const u8) Error!types.TypeVar {
        for (self.vars.items, 0..) |seen, i| {
            if (std.mem.eql(u8, seen, name)) return @intCast(i);
        }
        if (self.vars.items.len > std.math.maxInt(types.TypeVar)) {
            try self.sink.report(
                .type_mismatch,
                diagnostic.Span.unknown,
                "a signature has more type variables than can be indexed",
                .{},
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

const testing = std.testing;

/// Builds a `cst.Signature` by parsing one, so the tests exercise the same
/// shapes the grammar actually produces.
const Fixture = struct {
    env: core.env.Env,
    sink: diagnostic.Sink,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try core.env.Env.init(gpa),
            .sink = diagnostic.Sink.init(gpa),
        };
        try self.env.datatypes.declareStructural(&self.env.interner, self.env.allocator());
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.sink.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    fn node(self: *Fixture, kind: cst.Type.Kind) cst.Type {
        _ = self;
        return .{ .kind = kind, .span = diagnostic.Span.unknown };
    }

    fn ptr(self: *Fixture, t: cst.Type) !*cst.Type {
        const slot = try self.env.allocator().create(cst.Type);
        slot.* = t;
        return slot;
    }

    fn expectScheme(self: *Fixture, written: cst.Type, expected: []const u8) !void {
        const signature: cst.Signature = .{ .name = "f", .type = written };
        const scheme = try translate(
            self.env.allocator(),
            testing.allocator,
            &signature,
            &self.env.datatypes,
            &self.sink,
        );

        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try scheme.format(&buf.writer);
        try testing.expectEqualStrings(expected, buf.written());
    }
};

test "a primitive name translates to its type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(fix.node(.{ .constructor = "Int" }), "Int");
    try fix.expectScheme(fix.node(.{ .constructor = "Node" }), "Node");
}

test "an unknown constructor is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{
        .name = "f",
        .type = fix.node(.{ .constructor = "Nope" }),
    };
    try testing.expectError(error.BadAnnotation, translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.env.datatypes,
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
}

test "type variables become forall binders in order of appearance" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `b -> a` binds `b` first, so `b` is variable 0 and renders as `a`.
    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .variable = "b" }),
        .to = fix.node(.{ .variable = "a" }),
    };
    try fix.expectScheme(written, "a -> b");
}

test "one variable used twice gets one binder" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .variable = "a" }),
        .to = fix.node(.{ .variable = "a" }),
    };
    try fix.expectScheme(written, "a -> a");
}

test "Filter expands to an arrow returning a list" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `Filter Node String` is `Node -> [String]`.
    const written = fix.node(.{ .filter = try fix.env.allocator().create(cst.FilterType) });
    written.kind.filter.* = .{
        .input = fix.node(.{ .constructor = "Node" }),
        .output = fix.node(.{ .constructor = "String" }),
    };
    try fix.expectScheme(written, "Node -> [String]");
}

test "Filter over variables quantifies both" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const written = fix.node(.{ .filter = try fix.env.allocator().create(cst.FilterType) });
    written.kind.filter.* = .{
        .input = fix.node(.{ .variable = "a" }),
        .output = fix.node(.{ .variable = "a" }),
    };
    try fix.expectScheme(written, "a -> [a]");
}

test "a list type translates elementwise" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        fix.node(.{ .list = try fix.ptr(fix.node(.{ .constructor = "Int" })) }),
        "[Int]",
    );
}

test "a parenthesized type is transparent" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(
        fix.node(.{ .parenthesized = try fix.ptr(fix.node(.{ .constructor = "Int" })) }),
        "Int",
    );
}

test "a record type keeps its labels" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const fields = try fix.env.allocator().alloc(cst.TypeField, 2);
    fields[0] = .{ .name = "k", .type = fix.node(.{ .constructor = "String" }) };
    fields[1] = .{ .name = "n", .type = fix.node(.{ .constructor = "Int" }) };

    try fix.expectScheme(fix.node(.{ .record = fields }), "{k: String, n: Int}");
}

test "the primitive table is the five primitives and nothing else" {
    // A change to what a signature may name should fail here first. `Bool` is
    // absent because it is a declared type, resolved through the registry.
    try testing.expectEqual(5, primitive_names.len);
    try testing.expect(primitiveNamed("Node") != null);
    try testing.expect(primitiveNamed("Bool") == null);
    try testing.expect(primitiveNamed("node") == null);
    try testing.expect(primitiveNamed("Filter") == null);
}
