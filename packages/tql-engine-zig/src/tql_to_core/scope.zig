//! What a module's top-level names refer to: its own declarations, then the
//! modules it imports.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const datatypes = core.datatypes;

const ModuleId = core.ModuleId;

/// What a written name resolves to.
pub fn Resolved(comptime T: type) type {
    return union(enum) {
        missing,
        found: T,
        /// Two imports declare different things under the name.
        ambiguous: [2]ModuleId,
    };
}

/// A type name: a datatype or an alias.
pub const TypeName = union(enum) {
    datatype: datatypes.TypeId,
    alias: *const datatypes.Alias,
};

/// One module's view of the globals.
///
/// A module's own declaration hides an import's. Two imports declaring one
/// name are ambiguous only where the name is used.
pub const ModuleScope = struct {
    module: ModuleId,
    /// The modules whose every declaration is in scope unqualified.
    imports: []const ModuleId,
    interner: *const core.Interner,
    datatypes: *const datatypes.Registry,

    pub fn value(self: *const ModuleScope, name: []const u8) Resolved(core.SymbolId) {
        return self.resolve(core.SymbolId, name, declaredValue);
    }

    pub fn typeNamed(self: *const ModuleScope, name: []const u8) Resolved(TypeName) {
        return self.resolve(TypeName, name, declaredType);
    }

    fn resolve(
        self: *const ModuleScope,
        comptime T: type,
        name: []const u8,
        comptime declared: fn (*const ModuleScope, ModuleId, []const u8) ?T,
    ) Resolved(T) {
        if (declared(self, self.module, name)) |own| return .{ .found = own };
        var found: ?struct { item: T, module: ModuleId } = null;
        for (self.imports) |imported| {
            const item = declared(self, imported, name) orelse continue;
            if (found) |earlier| {
                if (!std.meta.eql(earlier.item, item)) return .{ .ambiguous = .{ earlier.module, imported } };
                continue;
            }
            found = .{ .item = item, .module = imported };
        }
        return if (found) |f| .{ .found = f.item } else .missing;
    }

    fn declaredValue(self: *const ModuleScope, module: ModuleId, name: []const u8) ?core.SymbolId {
        return self.interner.lookup(module, name);
    }

    fn declaredType(self: *const ModuleScope, module: ModuleId, name: []const u8) ?TypeName {
        if (self.datatypes.lookup(module, name)) |id| return .{ .datatype = id };
        if (self.datatypes.aliasNamed(module, name)) |alias| return .{ .alias = alias };
        return null;
    }

    /// Reports `name` as ambiguous between `modules` at `span`.
    pub fn reportAmbiguous(
        self: *const ModuleScope,
        sink: *diagnostic.Sink,
        span: diagnostic.Span,
        name: []const u8,
        modules: [2]ModuleId,
    ) !void {
        try sink.report(
            .ambiguous_name,
            span,
            "`{s}` is declared by both `{s}` and `{s}`",
            .{ name, self.interner.moduleName(modules[0]), self.interner.moduleName(modules[1]) },
        );
    }
};

const test_support = @import("../core/test_support.zig");

const Fixture = struct {
    env: core.env.Env,
    left: ModuleId,
    right: ModuleId,
    main: ModuleId,

    fn init() !Fixture {
        var env = try test_support.env(std.testing.allocator);
        errdefer env.deinit();
        return .{
            .left = try env.interner.declareModule("Left"),
            .right = try env.interner.declareModule("Right"),
            .main = try env.interner.declareModule("Main"),
            .env = env,
        };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
    }

    fn scope(self: *const Fixture, imports: []const ModuleId) ModuleScope {
        return .{
            .module = self.main,
            .imports = imports,
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
        };
    }
};

test "a module's own declaration hides an import's" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);
    const own = try fix.env.interner.intern(fix.main, "f", .vanilla);

    const s = fix.scope(&.{fix.left});
    try std.testing.expectEqual(own, s.value("f").found);
}

test "an imported name resolves to the imported module's declaration" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const imported = try fix.env.interner.intern(fix.left, "f", .vanilla);

    const s = fix.scope(&.{fix.left});
    try std.testing.expectEqual(imported, s.value("f").found);
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("g")));
}

test "two imports declaring one name are ambiguous" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);
    _ = try fix.env.interner.intern(fix.right, "f", .vanilla);

    const s = fix.scope(&.{ fix.left, fix.right });
    const resolved = s.value("f");
    try std.testing.expectEqual(fix.left, resolved.ambiguous[0]);
    try std.testing.expectEqual(fix.right, resolved.ambiguous[1]);
}

test "a module not imported is not in scope" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.right, "f", .vanilla);

    const s = fix.scope(&.{fix.left});
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("f")));
}

test "a type a module declares hides an imported one" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const own = try fix.env.datatypes.declare(&fix.env.interner, fix.main, "Bool", 0, &.{}, .{});

    const s = fix.scope(&.{.prelude});
    try std.testing.expectEqual(own, s.typeNamed("Bool").found.datatype);
}

test "a type resolves through an import" {
    var fix = try Fixture.init();
    defer fix.deinit();

    const s = fix.scope(&.{.prelude});
    try std.testing.expectEqual(fix.env.datatypes.boolId(), s.typeNamed("Bool").found.datatype);
}
