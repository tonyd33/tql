//! Module for converting surface TQL syntax to Core, a lower-level
//! lambda-style language.

const annotation = @import("tql_to_core/annotation.zig");
const desugar = @import("tql_to_core/desugar.zig");
const link_mod = @import("tql_to_core/link.zig");

/// Desugars source files into one linked `core.Program`.
pub const Desugarer = link_mod.Desugarer;
pub const Import = scope_mod.Import;
pub const Filter = scope_mod.Filter;

test {
    std.testing.refAllDecls(link_mod);
    std.testing.refAllDecls(desugar);
    std.testing.refAllDecls(@import("tql_to_core/resolve.zig"));
    std.testing.refAllDecls(@import("tql_to_core/scope.zig"));
    std.testing.refAllDecls(annotation);
}

const std = @import("std");
const core = @import("core.zig");
const cst = @import("lang/cst.zig");
const diagnostic = @import("diagnostic.zig");
const grammar = @import("lang/grammar.zig");
const parse = @import("parse.zig");
const test_support = core.test_support;
const scope_mod = @import("tql_to_core/scope.zig");
const ModuleScope = scope_mod.ModuleScope;

const testing = std.testing;
const types = core.types;
const Allocator = std.mem.Allocator;

/// Translates hand-built `cst.Type` signatures against an environment holding
/// the structural types.
const Fixture = struct {
    env: core.env.Env,
    sink: diagnostic.Sink,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try test_support.env(gpa),
            .sink = diagnostic.Sink.init(gpa),
        };
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.sink.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    /// The prelude's own view: every structural type, no imports.
    fn scope(self: *const Fixture) ModuleScope {
        return .{
            .module = .prelude,
            .imports = &.{},
            .exports = &.{.all},
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
        };
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
        try self.expectConstrained(&.{}, written, expected);
    }

    fn expectConstrained(
        self: *Fixture,
        context: []const cst.ClassConstraint,
        written: cst.Type,
        expected: []const u8,
    ) !void {
        const signature: cst.Signature = .{ .name = "f", .context = context, .type = written };
        const scheme = try annotation.translate(
            self.env.allocator(),
            testing.allocator,
            &signature,
            &self.scope(),
            &self.sink,
        );

        try testing.expectFmt(expected, "{f}", .{scheme});
    }
};

/// Parses, desugars and links `sources` against the typescript grammar, each
/// as a module importing every one before it, the last as the entry module.
/// No prelude source is linked, but each imports the primitives. The caller
/// owns the result.
fn link(sources: []const []const u8) !core.Program {
    const gpa = testing.allocator;

    var grammars = grammar.Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var parser = try parse.Parser.init(gpa);
    defer parser.deinit();

    var desugarer = try Desugarer.init(gpa);
    defer desugarer.deinit();

    var sink = diagnostic.Sink.init(gpa);
    defer sink.deinit();

    var modules: std.ArrayList(scope_mod.Import) = .empty;
    defer modules.deinit(gpa);
    try modules.append(gpa, .{ .module = .prelude });

    var entry_span = diagnostic.Span.unknown;
    for (sources, 0..) |source, i| {
        var parsed = try parser.parseCollecting(source, .entry);
        defer parsed.deinit();
        try testing.expect(!parsed.hasErrors());
        var name_buf: [16]u8 = undefined;
        const module = try desugarer.declareModule(try std.fmt.bufPrint(&name_buf, "M{d}", .{i}), .all);
        try desugarer.add(module, modules.items, parsed.source_file, g, &sink);
        try modules.append(gpa, .{ .module = module });
        entry_span = parsed.source_file.span;
    }
    return try desugarer.finish(entry_span, &sink);
}

// ============================================================================
//                              annotation
// ============================================================================

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
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
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

    try fix.expectScheme(fix.node(.{ .record = .{ .fields = fields } }), "{k: String, n: Int}");
}

test "a record type sorts its labels" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const fields = try fix.env.allocator().alloc(cst.TypeField, 2);
    fields[0] = .{ .name = "n", .type = fix.node(.{ .constructor = "Int" }) };
    fields[1] = .{ .name = "k", .type = fix.node(.{ .constructor = "String" }) };

    try fix.expectScheme(fix.node(.{ .record = .{ .fields = fields } }), "{k: String, n: Int}");
}

test "a row after the fields is a variable of the scheme" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const fields = try fix.env.allocator().alloc(cst.TypeField, 1);
    fields[0] = .{ .name = "start_byte", .type = fix.node(.{ .variable = "t" }) };
    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .record = .{ .fields = fields, .row = "r" } }),
        .to = fix.node(.{ .variable = "t" }),
    };
    try fix.expectScheme(written, "{start_byte: a | b} -> a");
}

test "Range and Point keep their names" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectScheme(fix.node(.{ .constructor = "Point" }), "Point");
}

test "a row variable used as a type is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .record = .{ .fields = &.{}, .row = "r" } }),
        .to = fix.node(.{ .variable = "r" }),
    };
    const signature: cst.Signature = .{ .name = "f", .type = written };
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
}

test "a record type with a repeated label is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const fields = try fix.env.allocator().alloc(cst.TypeField, 2);
    fields[0] = .{ .name = "a", .type = fix.node(.{ .constructor = "Int" }) };
    fields[1] = .{ .name = "a", .type = fix.node(.{ .constructor = "String" }) };
    const signature: cst.Signature = .{ .name = "f", .type = fix.node(.{ .record = .{ .fields = fields } }) };
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
}

test "a context constrains a variable of the type" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .variable = "a" }),
        .to = fix.node(.{ .constructor = "Int" }),
    };
    try fix.expectConstrained(&.{.{ .class = "Sized", .variable = "a" }}, written, "Sized a => a -> Int");
}

test "a context follows the type's variable order" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const written = fix.node(.{ .function = try fix.env.allocator().create(cst.FunctionType) });
    written.kind.function.* = .{
        .from = fix.node(.{ .variable = "x" }),
        .to = fix.node(.{ .variable = "y" }),
    };
    try fix.expectConstrained(
        &.{ .{ .class = "Eq", .variable = "y" }, .{ .class = "Ord", .variable = "x" } },
        written,
        "(Eq b, Ord a) => a -> b",
    );
}

/// `v0 -> v1 -> ... -> Int` over `count` distinct variables.
fn manyVariables(fix: *Fixture, count: usize) !cst.Type {
    const arena = fix.env.allocator();
    var t = fix.node(.{ .constructor = "Int" });
    var i = count;
    while (i > 0) {
        i -= 1;
        const arrow = try arena.create(cst.FunctionType);
        arrow.* = .{
            .from = fix.node(.{ .variable = try std.fmt.allocPrint(arena, "v{d}", .{i}) }),
            .to = t,
        };
        t = fix.node(.{ .function = arrow });
    }
    return t;
}

test "a signature may have as many variables as a scheme can number" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{ .name = "f", .type = try manyVariables(fix, 255) };
    const scheme = try annotation.translate(fix.env.allocator(), gpa, &signature, &fix.scope(), &fix.sink);
    try testing.expectEqual(255, scheme.quantified);
}

test "a signature with one variable too many is a limit" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{ .name = "f", .type = try manyVariables(fix, 256) };
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
    try testing.expectEqual(diagnostic.Category.limit, fix.sink.items()[0].category);
}

test "an unknown class is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{
        .name = "f",
        .context = &.{.{ .class = "Show", .variable = "a" }},
        .type = fix.node(.{ .variable = "a" }),
    };
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
}

test "a constrained variable absent from the type is rejected" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{
        .name = "f",
        .context = &.{.{ .class = "Eq", .variable = "b" }},
        .type = fix.node(.{ .variable = "a" }),
    };
    try testing.expectError(error.BadAnnotation, annotation.translate(
        fix.env.allocator(),
        gpa,
        &signature,
        &fix.scope(),
        &fix.sink,
    ));
    try testing.expectEqual(1, fix.sink.items().len);
}

// ============================================================================
//                              resolve and link
// ============================================================================

test "a field symbol carries the grammar id it resolved" {
    var program = try link(&.{"main = #name;"});
    defer program.deinit();

    var grammars = grammar.Registry.init(testing.allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    const field = program.env.interner.lookup(null, "field[name]").?;
    const field_what = program.env.interner.details(field).synthesized;
    try testing.expectEqualStrings("name", field_what.field.name);
    try testing.expectEqual(g.language.fieldIdForName("name"), field_what.field.id);

    // A primitive is not synthesized, and a synthesized symbol is not a primitive.
    const text = program.env.interner.lookup(.prelude, "text").?;
    try testing.expectEqual(core.PrimOp.text, program.env.interner.details(text).primop);
    try testing.expect(program.env.interner.details(field) == .synthesized);
}

test "a kind literal carries the grammar id it resolved" {
    var program = try link(&.{"main = is_kind :class_declaration;"});
    defer program.deinit();

    var grammars = grammar.Registry.init(testing.allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    const body = program.entryDefinitions()[0].body;
    const function = body.kind.apply.function.kind.symbol;
    try testing.expectEqual(core.PrimOp.is_kind, program.env.interner.details(function).primop);
    const kind = body.kind.apply.argument.kind.literal.kind;
    try testing.expectEqualStrings("class_declaration", kind.name);
    try testing.expectEqual(g.language.idForNodeKind("class_declaration", true), kind.id);
}

test "linked components order library callees before entry callers" {
    var program = try link(&.{
        \\helper x = x;
        \\wrapper x = helper x;
        ,
        "main = wrapper;",
    });
    defer program.deinit();

    try testing.expectEqualStrings("main", program.env.interner.spelling(program.entry));

    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(testing.allocator);
    for (program.components) |component| {
        for (component) |index| {
            try order.append(testing.allocator, program.env.interner.spelling(program.definitions[index].symbol));
        }
    }
    try testing.expectEqual(3, order.items.len);
    try testing.expectEqualStrings("helper", order.items[0]);
    try testing.expectEqualStrings("wrapper", order.items[1]);
    try testing.expectEqualStrings("main", order.items[2]);
}

test "a module may declare a datatype named like an imported alias" {
    var program = try link(&.{
        "type X = Int;",
        "data X = X Int; main = #name;",
    });
    defer program.deinit();

    const entry = program.env.interner.moduleOf(program.entry).?;
    try testing.expect(program.env.datatypes.lookup(entry, "X") != null);
}

test "a module may declare an alias named like an imported datatype" {
    var program = try link(&.{
        "data X = X Int;",
        "type X = Int; main = #name;",
    });
    defer program.deinit();

    const entry = program.env.interner.moduleOf(program.entry).?;
    try testing.expect(program.env.datatypes.aliasNamed(entry, "X") != null);
}
