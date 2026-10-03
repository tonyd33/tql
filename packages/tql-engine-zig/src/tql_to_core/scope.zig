//! What a module's top-level names refer to: its own declarations, then the
//! modules it imports.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const datatypes = core.datatypes;

const ModuleId = core.ModuleId;

/// What a written name resolves to.
pub fn Resolved(comptime T: type) type {
    return union(enum) {
        missing,
        found: T,
        failed: Failure,
    };
}

/// Why a written name resolves to nothing usable, beyond being undeclared.
pub const Failure = union(enum) {
    /// Two imports declare different things under the name.
    ambiguous: [2]ModuleId,
    /// No import is qualified as the name's qualifier.
    unknown_qualifier: []const u8,
};

/// A type name: a datatype or an alias.
pub const TypeName = union(enum) {
    datatype: datatypes.TypeId,
    alias: *const datatypes.Alias,
};

pub const Filter = cst.Filter;

/// What a filter is asked to admit.
const Subject = union(enum) {
    value: []const u8,
    type: []const u8,
    /// A constructor, admitted only through `T(..)` for its type.
    constructors_of: []const u8,

    fn of(item: cst.Item) Subject {
        return switch (item.kind) {
            .value => .{ .value = item.name },
            .type, .type_and_constructors => .{ .type = item.name },
        };
    }
};

fn admits(filter: Filter, subject: Subject) bool {
    return switch (filter) {
        .all => true,
        .only => |items| listed(items, subject),
        .hiding => |items| !listed(items, subject),
    };
}

fn listed(items: []const cst.Item, subject: Subject) bool {
    for (items) |item| {
        const matches = switch (subject) {
            .value => |name| item.kind == .value and std.mem.eql(u8, item.name, name),
            .type => |name| item.kind != .value and std.mem.eql(u8, item.name, name),
            .constructors_of => |name| item.kind == .type_and_constructors and std.mem.eql(u8, item.name, name),
        };
        if (matches) return true;
    }
    return false;
}

/// A module in scope through one import declaration.
pub const Import = struct {
    module: ModuleId,
    /// Set when the import is qualified-only.
    qualifier: ?[]const u8 = null,
    /// What the import takes of `module`'s exports.
    selects: Filter = .all,
};

/// One module's view of the globals.
///
/// A module's own declaration hides an import's. Two imports declaring one
/// name are ambiguous only where the name is used. A name written `Q.x` is
/// looked up only in the imports qualified as `Q`.
pub const ModuleScope = struct {
    module: ModuleId,
    imports: []const Import,
    /// What each module exports, by `ModuleId`.
    exports: []const Filter,
    interner: *const core.Interner,
    datatypes: *const datatypes.Registry,

    pub fn value(self: *const ModuleScope, written: []const u8) Resolved(core.SymbolId) {
        return self.resolve(core.SymbolId, written, declaredValue, valueSubject);
    }

    pub fn typeNamed(self: *const ModuleScope, written: []const u8) Resolved(TypeName) {
        return self.resolve(TypeName, written, declaredType, typeSubject);
    }

    fn resolve(
        self: *const ModuleScope,
        comptime T: type,
        written: []const u8,
        comptime declared: fn (*const ModuleScope, ModuleId, []const u8) ?T,
        comptime subjectOf: fn (*const ModuleScope, T, []const u8) Subject,
    ) Resolved(T) {
        const qualifier: ?[]const u8, const name = if (std.mem.cutScalarLast(u8, written, '.')) |cut|
            .{ cut[0], cut[1] }
        else
            .{ null, written };

        if (qualifier == null) {
            if (declared(self, self.module, name)) |own| return .{ .found = own };
        }
        var qualified = false;
        var found: ?struct { item: T, module: ModuleId } = null;
        for (self.imports) |import| {
            if (!optionalEql(import.qualifier, qualifier)) continue;
            qualified = true;
            const item = declared(self, import.module, name) orelse continue;
            const subject = subjectOf(self, item, name);
            if (!admits(self.exportsOf(import.module), subject) or !admits(import.selects, subject)) continue;
            if (found) |earlier| {
                if (!std.meta.eql(earlier.item, item)) {
                    return .{ .failed = .{ .ambiguous = .{ earlier.module, import.module } } };
                }
                continue;
            }
            found = .{ .item = item, .module = import.module };
        }
        if (found) |f| return .{ .found = f.item };
        if (qualifier) |q| {
            if (!qualified) return .{ .failed = .{ .unknown_qualifier = q } };
        }
        return .missing;
    }

    fn exportsOf(self: *const ModuleScope, module: ModuleId) Filter {
        return self.exports[@intFromEnum(module)];
    }

    fn declaredValue(self: *const ModuleScope, module: ModuleId, name: []const u8) ?core.SymbolId {
        return self.interner.lookup(module, name);
    }

    fn declaredType(self: *const ModuleScope, module: ModuleId, name: []const u8) ?TypeName {
        if (self.datatypes.lookup(module, name)) |id| return .{ .datatype = id };
        if (self.datatypes.aliasNamed(module, name)) |alias| return .{ .alias = alias };
        return null;
    }

    fn valueSubject(self: *const ModuleScope, symbol: core.SymbolId, name: []const u8) Subject {
        const owner = datatypes.ownerOf(self.interner, symbol) orelse return .{ .value = name };
        return .{ .constructors_of = self.datatypes.get(owner).name };
    }

    fn typeSubject(_: *const ModuleScope, _: TypeName, name: []const u8) Subject {
        return .{ .type = name };
    }

    /// Reports why `written` resolved to nothing usable.
    pub fn reportFailure(
        self: *const ModuleScope,
        sink: *diagnostic.Sink,
        span: diagnostic.Span,
        written: []const u8,
        failure: Failure,
    ) !void {
        switch (failure) {
            .ambiguous => |modules| try sink.report(
                .ambiguous_name,
                span,
                "`{s}` is declared by both `{s}` and `{s}`",
                .{ written, self.interner.moduleName(modules[0]), self.interner.moduleName(modules[1]) },
            ),
            .unknown_qualifier => |q| try sink.report(
                .unresolved_name,
                span,
                "no import is qualified as `{s}`",
                .{q},
            ),
        }
    }

    /// Reports each export item this module does not declare, and each import
    /// item its module does not export. Returns whether there were none.
    pub fn checkItems(self: *const ModuleScope, sink: *diagnostic.Sink) !bool {
        var ok = try self.checkList(self.module, .all, self.exportsOf(self.module), sink);
        for (self.imports) |import| {
            ok = try self.checkList(import.module, self.exportsOf(import.module), import.selects, sink) and ok;
        }
        return ok;
    }

    fn checkList(self: *const ModuleScope, module: ModuleId, exports: Filter, list: Filter, sink: *diagnostic.Sink) !bool {
        const items = switch (list) {
            .all => return true,
            .only, .hiding => |items| items,
        };
        var ok = true;
        for (items) |item| ok = try self.checkItem(module, exports, item, sink) and ok;
        return ok;
    }

    /// Whether `item` names something `module` declares and `exports` admits.
    fn checkItem(
        self: *const ModuleScope,
        module: ModuleId,
        exports: Filter,
        item: cst.Item,
        sink: *diagnostic.Sink,
    ) !bool {
        const declared = admits(exports, Subject.of(item)) and switch (item.kind) {
            .value => if (self.interner.lookup(module, item.name)) |symbol|
                datatypes.ownerOf(self.interner, symbol) == null
            else
                false,
            .type, .type_and_constructors => declaredType(self, module, item.name) != null,
        };
        if (!declared) {
            if (module == self.module) {
                try sink.report(.unresolved_name, item.span, "`{s}` is not declared in this module", .{item.name});
            } else {
                try sink.report(
                    .unresolved_name,
                    item.span,
                    "`{s}` does not export `{s}`",
                    .{ self.interner.moduleName(module), item.name },
                );
            }
            return false;
        }
        if (item.kind != .type_and_constructors) return true;
        if (declaredType(self, module, item.name).? == .alias) {
            try sink.report(.unresolved_name, item.span, "`{s}` is an alias and has no constructors", .{item.name});
            return false;
        }
        if (admits(exports, .{ .constructors_of = item.name })) return true;
        try sink.report(
            .unresolved_name,
            item.span,
            "`{s}` does not export the constructors of `{s}`",
            .{ self.interner.moduleName(module), item.name },
        );
        return false;
    }
};

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const test_support = @import("../core/test_support.zig");

const Fixture = struct {
    env: core.env.Env,
    sink: diagnostic.Sink,
    /// By `ModuleId`: the prelude, then `left`, `right` and `main`.
    exports: [4]Filter = @splat(.all),
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
            .sink = diagnostic.Sink.init(std.testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.sink.deinit();
        self.env.deinit();
    }

    fn scope(self: *const Fixture, imports: []const Import) ModuleScope {
        return .{
            .module = self.main,
            .imports = imports,
            .exports = &self.exports,
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
        };
    }

    /// Declares `name` in `module` with one nullary constructor per spelling.
    fn datatype(self: *Fixture, module: ModuleId, name: []const u8, constructors: []const []const u8) !void {
        const arena = self.env.allocator();
        const declared = try arena.alloc(datatypes.Constructor, constructors.len);
        for (constructors, declared, 0..) |c, *slot, tag| {
            slot.* = .{ .symbol = try self.env.interner.intern(module, c, .vanilla), .tag = @intCast(tag), .fields = &.{} };
        }
        _ = try self.env.datatypes.declare(&self.env.interner, module, name, 0, declared, .{});
    }
};

test "a module's own declaration hides an import's" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);
    const own = try fix.env.interner.intern(fix.main, "f", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left }});
    try std.testing.expectEqual(own, s.value("f").found);
}

test "an imported name resolves to the imported module's declaration" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const imported = try fix.env.interner.intern(fix.left, "f", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left }});
    try std.testing.expectEqual(imported, s.value("f").found);
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("g")));
}

test "two imports declaring one name are ambiguous" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);
    _ = try fix.env.interner.intern(fix.right, "f", .vanilla);

    const s = fix.scope(&.{ .{ .module = fix.left }, .{ .module = fix.right } });
    const modules = s.value("f").failed.ambiguous;
    try std.testing.expectEqual(fix.left, modules[0]);
    try std.testing.expectEqual(fix.right, modules[1]);
}

test "a module imported twice is not ambiguous with itself" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const f = try fix.env.interner.intern(fix.left, "f", .vanilla);

    const s = fix.scope(&.{ .{ .module = fix.left }, .{ .module = fix.left } });
    try std.testing.expectEqual(f, s.value("f").found);
}

test "a module not imported is not in scope" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.right, "f", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left }});
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("f")));
}

test "a type a module declares hides an imported one" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const own = try fix.env.datatypes.declare(&fix.env.interner, fix.main, "Bool", 0, &.{}, .{});

    const s = fix.scope(&.{.{ .module = .prelude }});
    try std.testing.expectEqual(own, s.typeNamed("Bool").found.datatype);
}

test "a type resolves through an import" {
    var fix = try Fixture.init();
    defer fix.deinit();

    const s = fix.scope(&.{.{ .module = .prelude }});
    try std.testing.expectEqual(fix.env.datatypes.boolId(), s.typeNamed("Bool").found.datatype);
}

test "a qualified import is reached only through its qualifier" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const f = try fix.env.interner.intern(fix.left, "f", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left, .qualifier = "L" }});
    try std.testing.expectEqual(f, s.value("L.f").found);
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("f")));
}

test "a qualified name does not reach the module's own declarations" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.main, "f", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left, .qualifier = "L" }});
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("L.f")));
}

test "a qualifier no import declares is reported as such" {
    var fix = try Fixture.init();
    defer fix.deinit();

    const s = fix.scope(&.{.{ .module = fix.left }});
    try std.testing.expectEqualStrings("Q", s.value("Q.f").failed.unknown_qualifier);
}

test "imports sharing a qualifier merge under it" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const f = try fix.env.interner.intern(fix.left, "f", .vanilla);
    const g = try fix.env.interner.intern(fix.right, "g", .vanilla);

    const s = fix.scope(&.{
        .{ .module = fix.left, .qualifier = "Q" },
        .{ .module = fix.right, .qualifier = "Q" },
    });
    try std.testing.expectEqual(f, s.value("Q.f").found);
    try std.testing.expectEqual(g, s.value("Q.g").found);
}

test "an import list takes only what it names" {
    var fix = try Fixture.init();
    defer fix.deinit();
    const f = try fix.env.interner.intern(fix.left, "f", .vanilla);
    _ = try fix.env.interner.intern(fix.left, "g", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left, .selects = .{ .only = &.{.{ .name = "f", .kind = .value }} } }});
    try std.testing.expectEqual(f, s.value("f").found);
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("g")));
}

test "a hiding list takes everything it does not name" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);
    const g = try fix.env.interner.intern(fix.left, "g", .vanilla);

    const s = fix.scope(&.{.{ .module = fix.left, .selects = .{ .hiding = &.{.{ .name = "f", .kind = .value }} } }});
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("f")));
    try std.testing.expectEqual(g, s.value("g").found);
}

test "a name the module does not export is not imported" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "hidden", .vanilla);

    fix.exports[@intFromEnum(fix.left)] = .{ .only = &.{} };
    const s = fix.scope(&.{.{ .module = fix.left }});
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("hidden")));
}

test "constructors come only with their type's (..)" {
    var fix = try Fixture.init();
    defer fix.deinit();
    try fix.datatype(fix.left, "T", &.{"C"});

    const s = fix.scope(&.{.{ .module = fix.left }});
    fix.exports[@intFromEnum(fix.left)] = .{ .only = &.{.{ .name = "T", .kind = .type }} };
    try std.testing.expect(s.typeNamed("T") == .found);
    try std.testing.expectEqual(.missing, std.meta.activeTag(s.value("C")));

    fix.exports[@intFromEnum(fix.left)] = .{ .only = &.{.{ .name = "T", .kind = .type_and_constructors }} };
    try std.testing.expect(s.value("C") == .found);
}

test "an import item the module does not export is reported" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.left, "f", .vanilla);

    fix.exports[@intFromEnum(fix.left)] = .{ .only = &.{} };
    const s = fix.scope(&.{.{ .module = fix.left, .selects = .{ .only = &.{.{ .name = "f", .kind = .value }} } }});
    try std.testing.expect(!try s.checkItems(&fix.sink));
    try std.testing.expectEqualStrings("`Left` does not export `f`", fix.sink.items()[0].message);
}

test "importing the constructors of an abstract type is reported" {
    var fix = try Fixture.init();
    defer fix.deinit();
    try fix.datatype(fix.left, "T", &.{"C"});

    fix.exports[@intFromEnum(fix.left)] = .{ .only = &.{.{ .name = "T", .kind = .type }} };
    const s = fix.scope(&.{.{
        .module = fix.left,
        .selects = .{ .only = &.{.{ .name = "T", .kind = .type_and_constructors }} },
    }});
    try std.testing.expect(!try s.checkItems(&fix.sink));
    try std.testing.expectEqualStrings("`Left` does not export the constructors of `T`", fix.sink.items()[0].message);
}

test "an export item the module does not declare is reported" {
    var fix = try Fixture.init();
    defer fix.deinit();
    _ = try fix.env.interner.intern(fix.main, "f", .vanilla);

    const s = fix.scope(&.{});
    fix.exports[@intFromEnum(fix.main)] = .{ .only = &.{.{ .name = "f", .kind = .value }} };
    try std.testing.expect(try s.checkItems(&fix.sink));
    fix.exports[@intFromEnum(fix.main)] = .{ .only = &.{.{ .name = "g", .kind = .value }} };
    try std.testing.expect(!try s.checkItems(&fix.sink));
    try std.testing.expectEqualStrings("`g` is not declared in this module", fix.sink.items()[0].message);
}
