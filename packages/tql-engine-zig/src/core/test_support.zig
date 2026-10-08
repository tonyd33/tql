//! Fixtures shared by the unit tests of the passes below the engine.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = @import("datatypes.zig");
const diagnostic = @import("../diagnostic.zig");
const primitives = @import("../primitives.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// An environment holding `List` and `Bool` with their constructors, and
/// nothing else. The caller owns it.
pub fn env(gpa: Allocator) !core.env.Env {
    var e = try core.env.Env.init(gpa);
    errdefer e.deinit();
    try declareStructural(&e);
    return e;
}

/// Reserves the built-in types and fills in the constructors of `List` and
/// `Bool` in the shape `prelude.tql` declares them.
pub fn declareStructural(e: *core.env.Env) !void {
    const registry = &e.datatypes;
    const interner = &e.interner;
    const arena = e.allocator();
    try registry.reserveBuiltins(interner);

    const element = types.variable_type(0);
    const self_ref = try types.constructed(
        arena,
        registry.listId(),
        types.list_spelling,
        &.{element},
    );
    const cons_fields = try arena.dupe(types.Type, &.{ element, self_ref });
    try e.setConstructors(registry.listId(), try arena.dupe(datatypes.Constructor, &.{
        .{ .symbol = try interner.intern(.prelude, "Nil", .vanilla), .tag = 0, .fields = &.{} },
        .{ .symbol = try interner.intern(.prelude, "Cons", .vanilla), .tag = 1, .fields = cons_fields },
    }));

    try e.setConstructors(registry.boolId(), try arena.dupe(datatypes.Constructor, &.{
        .{ .symbol = try interner.intern(.prelude, "False", .vanilla), .tag = 0, .fields = &.{} },
        .{ .symbol = try interner.intern(.prelude, "True", .vanilla), .tag = 1, .fields = &.{} },
    }));
}

/// A constructor's spelling and its field types.
pub const Constructor = struct { []const u8, []const types.Type };

/// Declares `name` in `module` with `constructors`, tagged in order.
pub fn declareDatatype(
    e: *core.env.Env,
    module: symbols.ModuleId,
    name: []const u8,
    constructors: []const Constructor,
) !void {
    const arena = e.allocator();
    const declared = try arena.alloc(datatypes.Constructor, constructors.len);
    for (constructors, declared, 0..) |c, *slot, tag| {
        slot.* = .{
            .symbol = try e.interner.intern(module, c[0], .vanilla),
            .tag = @intCast(tag),
            .fields = try arena.dupe(types.Type, c[1]),
        };
    }
    const id = try e.datatypes.declare(&e.interner, module, try arena.dupe(u8, name), 0, &.{}, .{});
    try e.setConstructors(id, declared);
}

/// Assembles a `core.Program` from hand-built definitions over `env`'s
/// environment.
pub const ProgramBuilder = struct {
    env: core.env.Env,
    definitions: std.ArrayList(core.Definition) = .empty,

    pub fn init(gpa: Allocator) !ProgramBuilder {
        return .{ .env = try env(gpa) };
    }

    pub fn deinit(self: *ProgramBuilder) void {
        self.env.deinit();
    }

    pub fn terms(self: *const ProgramBuilder) core.Builder {
        return .{ .allocator = self.env.allocator() };
    }

    /// The global spelled `spelling`, interned on first use.
    pub fn global(self: *ProgramBuilder, spelling: []const u8) !core.SymbolId {
        return self.env.interner.lookup(.prelude, spelling) orelse
            try self.env.interner.intern(.prelude, spelling, .vanilla);
    }

    /// The `op[...]` symbol desugaring synthesizes for `scalar`, with its
    /// scheme.
    pub fn operator(self: *ProgramBuilder, scalar: core.Scalar) !core.SymbolId {
        var buf: [8]u8 = undefined;
        const spelling = try std.fmt.bufPrint(&buf, "op[{s}]", .{scalar.spelling()});
        const id = try self.env.interner.internOrGet(spelling, .{ .synthesized = .{ .operator = scalar } });
        try self.env.setScheme(id, try primitives.operatorScheme(self.env.allocator(), &self.env.datatypes, scalar));
        return id;
    }

    /// A fresh local binder.
    pub fn local(self: *ProgramBuilder, spelling: []const u8) !core.SymbolId {
        return try self.env.interner.fresh(spelling);
    }

    /// Declares `name` in the prelude with `constructors`, tagged in order.
    pub fn datatype(
        self: *ProgramBuilder,
        name: []const u8,
        constructors: []const Constructor,
    ) !void {
        try declareDatatype(&self.env, .prelude, name, constructors);
    }

    pub fn define(self: *ProgramBuilder, name: core.SymbolId, body: core.Term) !void {
        try self.definitions.append(self.env.allocator(), .{
            .symbol = name,
            .body = body,
            .span = diagnostic.Span.unknown,
        });
    }

    pub fn symbol(self: *const ProgramBuilder, id: core.SymbolId) core.Term {
        return self.terms().symbol(id, diagnostic.Span.unknown);
    }

    pub fn number(self: *const ProgramBuilder, n: i64) core.Term {
        return self.terms().literal(.{ .number = n }, diagnostic.Span.unknown);
    }

    pub fn lambda(self: *const ProgramBuilder, parameters: []const core.SymbolId, body: core.Term) !core.Term {
        var result = body;
        var i = parameters.len;
        while (i > 0) {
            i -= 1;
            result = try self.terms().lambda(parameters[i], result, diagnostic.Span.unknown);
        }
        return result;
    }

    pub fn apply(self: *const ProgramBuilder, function: core.Term, arguments: []const core.Term) !core.Term {
        return try self.terms().applyMany(function, arguments, diagnostic.Span.unknown);
    }

    /// `case scrutinee of { C x_1 .. x_n -> body; ... }`.
    pub fn case(
        self: *const ProgramBuilder,
        scrutinee: core.Term,
        alternatives: []const core.Case.Alternative,
    ) !core.Term {
        const copies = try self.terms().dupeSlice(core.Case.Alternative, alternatives);
        for (copies) |*alternative| {
            alternative.binders = try self.terms().dupeSlice(core.SymbolId, alternative.binders);
        }
        return try self.terms().case(scrutinee, copies, diagnostic.Span.unknown);
    }

    pub fn let(self: *const ProgramBuilder, name: core.SymbolId, value: core.Term, body: core.Term) !core.Term {
        return try self.terms().let(name, value, body, diagnostic.Span.unknown);
    }

    pub fn letrec(self: *const ProgramBuilder, bindings: []const core.Letrec.Binding, body: core.Term) !core.Term {
        return try self.terms().letrec(
            try self.terms().dupeSlice(core.Letrec.Binding, bindings),
            body,
            diagnostic.Span.unknown,
        );
    }

    /// A program over the builder's environment whose entry is `entry`, with
    /// every definition its own component, in definition order. The program
    /// borrows the environment: deinit the builder, not the program.
    pub fn program(self: *ProgramBuilder, entry: core.SymbolId) !core.Program {
        const arena = self.env.allocator();
        const components = try arena.alloc([]const u32, self.definitions.items.len);
        for (components, 0..) |*component, i| component.* = try arena.dupe(u32, &.{@intCast(i)});
        return .{
            .env = self.env,
            .definitions = self.definitions.items,
            .components = components,
            .entry = entry,
            .entry_offset = 0,
        };
    }
};

/// Expect `t` to print as `expected`.
pub fn expectPrints(pb: *const ProgramBuilder, expected: []const u8, t: core.Term) !void {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    const printer: core.Printer = .{ .interner = &pb.env.interner };
    try printer.term(t, &w.writer);
    try std.testing.expectEqualStrings(expected, w.written());
}
