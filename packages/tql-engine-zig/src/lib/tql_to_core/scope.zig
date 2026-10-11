//! What a module's top-level names refer to: its own declarations, then the
//! modules it imports.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const classes = core.classes;
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

/// A name in the type namespace: a datatype, an alias, a primitive, or a
/// class.
pub const TypeName = union(enum) {
    datatype: datatypes.TypeId,
    alias: *const datatypes.Alias,
    class: classes.ClassId,
};

pub const Filter = cst.Filter;

/// What a filter is asked to admit.
const Subject = union(enum) {
    value: []const u8,
    type: []const u8,
    /// A constructor, admitted only through `T(..)` for its type.
    constructor_of: datatypes.TypeId,
    /// A method, admitted by its own name or through `C(..)` for its class.
    method: struct { name: []const u8, class: classes.ClassId },
    synonym: []const u8,
};

/// Whether `filter`, applied to the exports `from`, admits `subject`.
fn admits(filter: Filter, subject: Subject, from: *const Exports) bool {
    return switch (filter) {
        .all => true,
        .only => |items| listed(items, subject, from),
        .hiding => |items| !listed(items, subject, from),
    };
}

fn listed(items: []const cst.Item, subject: Subject, from: *const Exports) bool {
    for (items) |item| {
        const matches = switch (subject) {
            .value => |name| item.kind == .value and std.mem.eql(u8, item.name, name),
            .type => |name| (item.kind == .type or item.kind == .type_and_constructors) and std.mem.eql(u8, item.name, name),
            .constructor_of => |owner| membersOf(item, from, .{ .datatype = owner }),
            .method => |m| (item.kind == .value and std.mem.eql(u8, item.name, m.name)) or
                membersOf(item, from, .{ .class = m.class }),
            .synonym => |name| item.kind == .synonym and std.mem.eql(u8, item.name, name),
        };
        if (matches) return true;
    }
    return false;
}

/// Whether `item` is `T(..)` for the `T` that `from` exports as `owner`.
fn membersOf(item: cst.Item, from: *const Exports, owner: TypeName) bool {
    if (item.kind != .type_and_constructors) return false;
    const exported = from.types.get(item.name) orelse return false;
    return std.meta.eql(exported, owner);
}

/// What a module exports, by spelling. A module may export what it imports.
pub const Exports = struct {
    values: std.StringArrayHashMapUnmanaged(core.SymbolId) = .empty,
    types: std.StringArrayHashMapUnmanaged(TypeName) = .empty,
};

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
/// A module's own declaration hides an import's. Two imports bringing
/// different things under one name are ambiguous only where the name is used.
/// A name written `Q.x` is looked up only in the imports qualified as `Q`.
pub const ModuleScope = struct {
    module: ModuleId,
    imports: []const Import,
    /// What each of `imports` takes of its module's exports, in order.
    visible: []const Exports,
    /// What each module linked before this one exports, by `ModuleId`.
    exports: []const Exports,
    /// What names resolve to, and where a tuple type the module writes is
    /// declared.
    env: *core.env.Env,

    /// `module`'s view, taking from each of `imports` what it selects of
    /// `exports`.
    pub fn init(
        arena: std.mem.Allocator,
        module: ModuleId,
        imports: []const Import,
        exports: []const Exports,
        env: *core.env.Env,
    ) !ModuleScope {
        const visible = try arena.alloc(Exports, imports.len);
        for (imports, visible) |import, *taken| {
            const from = &exports[@intFromEnum(import.module)];
            if (import.selects == .all) {
                taken.* = from.*;
                continue;
            }
            taken.* = .{};
            var values = from.values.iterator();
            while (values.next()) |entry| {
                if (!admits(import.selects, valueSubject(env, entry.value_ptr.*, entry.key_ptr.*), from)) continue;
                try taken.values.put(arena, entry.key_ptr.*, entry.value_ptr.*);
            }
            var types = from.types.iterator();
            while (types.next()) |entry| {
                if (!admits(import.selects, .{ .type = entry.key_ptr.* }, from)) continue;
                try taken.types.put(arena, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return .{ .module = module, .imports = imports, .visible = visible, .exports = exports, .env = env };
    }

    pub fn value(self: *const ModuleScope, written: []const u8) Resolved(core.SymbolId) {
        return self.resolve(core.SymbolId, written, declaredValue, takenValue);
    }

    pub fn typeNamed(self: *const ModuleScope, written: []const u8) Resolved(TypeName) {
        return self.resolve(TypeName, written, declaredType, takenType);
    }

    fn resolve(
        self: *const ModuleScope,
        comptime T: type,
        written: []const u8,
        comptime declared: fn (*const ModuleScope, ModuleId, []const u8) ?T,
        comptime taken: fn (*const Exports, []const u8) ?T,
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
        for (self.imports, self.visible) |import, *visible| {
            if (!optionalEql(import.qualifier, qualifier)) continue;
            qualified = true;
            const item = taken(visible, name) orelse continue;
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

    fn declaredValue(self: *const ModuleScope, module: ModuleId, name: []const u8) ?core.SymbolId {
        return self.env.interner.lookup(module, name);
    }

    fn takenValue(visible: *const Exports, name: []const u8) ?core.SymbolId {
        return visible.values.get(name);
    }

    pub fn declaredType(self: *const ModuleScope, module: ModuleId, name: []const u8) ?TypeName {
        if (self.env.datatypes.lookup(module, name)) |id| return .{ .datatype = id };
        if (self.env.datatypes.aliasNamed(module, name)) |alias| return .{ .alias = alias };
        if (self.env.classes.lookup(module, name)) |id| return .{ .class = id };
        return null;
    }

    fn takenType(visible: *const Exports, name: []const u8) ?TypeName {
        return visible.types.get(name);
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
                .{ written, self.env.interner.moduleName(modules[0]), self.env.interner.moduleName(modules[1]) },
            ),
            .unknown_qualifier => |q| try sink.report(
                .unresolved_name,
                span,
                "no import is qualified as `{s}`",
                .{q},
            ),
        }
    }

    /// Reports each import item its module does not export. Returns whether
    /// there were none.
    pub fn checkImports(self: *const ModuleScope, sink: *diagnostic.Sink) !bool {
        var ok = true;
        for (self.imports) |import| {
            const items = switch (import.selects) {
                .all => continue,
                .only, .hiding => |items| items,
            };
            for (items) |item| ok = try self.checkImported(import.module, item, sink) and ok;
        }
        return ok;
    }

    /// Whether `item` names something `module` exports.
    fn checkImported(self: *const ModuleScope, module: ModuleId, item: cst.Item, sink: *diagnostic.Sink) !bool {
        const exports = &self.exports[@intFromEnum(module)];
        const exported = switch (item.kind) {
            .value, .synonym => if (exports.values.get(item.name)) |symbol| self.itemNames(item, symbol) else false,
            .type, .type_and_constructors => exports.types.contains(item.name),
            .module => {
                try sink.report(.unresolved_name, item.span, "`module {s}` belongs in an export list", .{item.name});
                return false;
            },
        };
        if (!exported) {
            try sink.report(
                .unresolved_name,
                item.span,
                "`{s}` does not export `{s}`",
                .{ self.env.interner.moduleName(module), item.name },
            );
            return false;
        }
        if (item.kind != .type_and_constructors) return true;
        const name = exports.types.get(item.name).?;
        const noun = try membersNoun(name, item, sink) orelse return false;
        if (self.exportsMembers(exports, name)) return true;
        try sink.report(
            .unresolved_name,
            item.span,
            "`{s}` does not export the {s} of `{s}`",
            .{ self.env.interner.moduleName(module), noun, item.name },
        );
        return false;
    }

    /// Whether a `.value` or `.synonym` item may name `symbol`: a value item
    /// names no constructor, and a synonym item names a synonym.
    fn itemNames(self: *const ModuleScope, item: cst.Item, symbol: core.SymbolId) bool {
        return switch (item.kind) {
            .value => datatypes.ownerOf(&self.env.interner, symbol) == null,
            .synonym => self.env.interner.details(symbol) == .synonym,
            else => unreachable,
        };
    }

    /// Whether `exports` holds every constructor or method of `name`.
    fn exportsMembers(self: *const ModuleScope, exports: *const Exports, name: TypeName) bool {
        switch (name) {
            .datatype => |id| for (self.env.datatypes.get(id).constructors) |c| {
                if (!self.holds(exports, c.symbol)) return false;
            },
            .class => |id| for (self.env.classes.get(id).methods) |m| {
                if (!self.holds(exports, m)) return false;
            },
            .alias => {},
        }
        return true;
    }

    fn holds(self: *const ModuleScope, exports: *const Exports, symbol: core.SymbolId) bool {
        return exports.values.get(self.env.interner.spelling(symbol)) == symbol;
    }

    /// What `T(..)` names the members of. Reports an alias, which has none.
    fn membersNoun(name: TypeName, item: cst.Item, sink: *diagnostic.Sink) !?[]const u8 {
        return switch (name) {
            .datatype => "constructors",
            .class => "methods",
            .alias => {
                try sink.report(.unresolved_name, item.span, "`{s}` is an alias and has no constructors", .{item.name});
                return null;
            },
        };
    }

    /// Builds what this module exports, from its export list. Reports each
    /// item naming nothing in scope, and each spelling it exports as two
    /// different things. Returns null when there was one.
    ///
    /// Preconditions:
    /// - Every top-level name of this module is declared.
    pub fn exportsOf(self: *const ModuleScope, arena: std.mem.Allocator, list: Filter, sink: *diagnostic.Sink) !?Exports {
        const items = switch (list) {
            .all => return try self.ownExports(arena),
            .only, .hiding => |items| items,
        };
        const reported = sink.items().len;
        var out: Exports = .{};
        for (items) |item| try self.exportItem(arena, item, &out, sink);
        return if (sink.items().len == reported) out else null;
    }

    fn exportItem(self: *const ModuleScope, arena: std.mem.Allocator, item: cst.Item, out: *Exports, sink: *diagnostic.Sink) !void {
        switch (item.kind) {
            .value, .synonym => {
                const symbol = try self.inScope(core.SymbolId, self.value(item.name), item, sink) orelse return;
                if (!self.itemNames(item, symbol)) return try reportUndeclared(item, sink);
                try self.put(core.SymbolId, arena, &out.values, self.env.interner.spelling(symbol), symbol, item.span, sink);
            },
            .type, .type_and_constructors => {
                const name = try self.inScope(TypeName, self.typeNamed(item.name), item, sink) orelse return;
                if (item.kind == .type_and_constructors) {
                    _ = try membersNoun(name, item, sink) orelse return;
                    switch (name) {
                        .datatype => |id| for (self.env.datatypes.get(id).constructors) |c| {
                            try self.exportMember(arena, c.symbol, out, item.span, sink);
                        },
                        .class => |id| for (self.env.classes.get(id).methods) |m| {
                            try self.exportMember(arena, m, out, item.span, sink);
                        },
                        .alias => unreachable,
                    }
                }
                try self.put(TypeName, arena, &out.types, self.typeSpelling(name), name, item.span, sink);
            },
            .module => {
                if (std.mem.eql(u8, item.name, self.env.interner.moduleName(self.module))) {
                    return try self.merge(arena, out, &try self.ownExports(arena), item.span, sink);
                }
                var imported = false;
                for (self.imports, self.visible) |import, *visible| {
                    if (import.qualifier != null) continue;
                    if (!std.mem.eql(u8, self.env.interner.moduleName(import.module), item.name)) continue;
                    imported = true;
                    try self.merge(arena, out, visible, item.span, sink);
                }
                if (!imported) {
                    try sink.report(.unresolved_name, item.span, "`{s}` is not imported unqualified", .{item.name});
                }
            },
        }
    }

    /// Adds `entity` under `spelling`. Reports a different entity already
    /// exported under it.
    fn put(
        self: *const ModuleScope,
        comptime T: type,
        arena: std.mem.Allocator,
        map: *std.StringArrayHashMapUnmanaged(T),
        spelling: []const u8,
        entity: T,
        span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) !void {
        const slot = try map.getOrPut(arena, spelling);
        if (!slot.found_existing) {
            slot.value_ptr.* = entity;
            return;
        }
        if (std.meta.eql(slot.value_ptr.*, entity)) return;
        try sink.report(
            .conflicting_export,
            span,
            "`{s}` is exported as both `{s}.{s}` and `{s}.{s}`",
            .{
                spelling,
                self.env.interner.moduleName(self.origin(T, slot.value_ptr.*)),
                spelling,
                self.env.interner.moduleName(self.origin(T, entity)),
                spelling,
            },
        );
    }

    /// The module that declares `entity`.
    fn origin(self: *const ModuleScope, comptime T: type, entity: T) ModuleId {
        if (T == core.SymbolId) return self.env.interner.moduleOf(entity).?;
        return switch (entity) {
            .datatype => |id| self.env.datatypes.get(id).module,
            .class => |id| self.env.classes.get(id).name.module.?,
            .alias => |alias| alias.module,
        };
    }

    /// Adds everything `from` holds.
    fn merge(self: *const ModuleScope, arena: std.mem.Allocator, out: *Exports, from: *const Exports, span: diagnostic.Span, sink: *diagnostic.Sink) !void {
        var values = from.values.iterator();
        while (values.next()) |entry| try self.put(core.SymbolId, arena, &out.values, entry.key_ptr.*, entry.value_ptr.*, span, sink);
        var types = from.types.iterator();
        while (types.next()) |entry| try self.put(TypeName, arena, &out.types, entry.key_ptr.*, entry.value_ptr.*, span, sink);
    }

    /// Returns what a lookup found. Reports a failed or missing one.
    fn inScope(self: *const ModuleScope, comptime T: type, resolved: Resolved(T), item: cst.Item, sink: *diagnostic.Sink) !?T {
        switch (resolved) {
            .found => |found| return found,
            .missing => {
                try reportUndeclared(item, sink);
                return null;
            },
            .failed => |failure| {
                try self.reportFailure(sink, item.span, item.name, failure);
                return null;
            },
        }
    }

    fn reportUndeclared(item: cst.Item, sink: *diagnostic.Sink) !void {
        try sink.report(.unresolved_name, item.span, "`{s}` is not declared in this module", .{item.name});
    }

    /// The spelling `name` was declared with.
    fn typeSpelling(self: *const ModuleScope, name: TypeName) []const u8 {
        return switch (name) {
            .datatype => |id| self.env.datatypes.get(id).name,
            .alias => |alias| alias.name,
            .class => |id| self.env.classes.spelling(id),
        };
    }

    /// Adds `member`, a constructor or method, when this module declares or
    /// imports it.
    fn exportMember(
        self: *const ModuleScope,
        arena: std.mem.Allocator,
        member: core.SymbolId,
        out: *Exports,
        span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) !void {
        if (!self.reaches(member)) return;
        try self.put(core.SymbolId, arena, &out.values, self.env.interner.spelling(member), member, span, sink);
    }

    /// Whether this module declares `symbol`, or an import takes it.
    fn reaches(self: *const ModuleScope, symbol: core.SymbolId) bool {
        if (self.env.interner.moduleOf(symbol) == self.module) return true;
        for (self.visible) |*visible| {
            if (self.holds(visible, symbol)) return true;
        }
        return false;
    }

    /// Everything this module declares, its constructors and methods
    /// included.
    fn ownExports(self: *const ModuleScope, arena: std.mem.Allocator) !Exports {
        var out: Exports = .{};
        var symbols = self.env.interner.by_name.iterator();
        while (symbols.next()) |entry| {
            if (entry.key_ptr.module != self.module) continue;
            try out.values.put(arena, entry.key_ptr.name, entry.value_ptr.*);
        }
        for (self.env.datatypes.datatypes.items, 0..) |d, i| {
            if (d.module != self.module) continue;
            try out.types.put(arena, d.name, .{ .datatype = @enumFromInt(i) });
        }
        var aliases = self.env.datatypes.aliases.iterator();
        while (aliases.next()) |entry| {
            if (entry.key_ptr.module != self.module) continue;
            try out.types.put(arena, entry.key_ptr.name, .{ .alias = entry.value_ptr.* });
        }
        for (self.env.classes.classes.items, 0..) |c, i| {
            if (c.name.module != self.module) continue;
            try out.types.put(arena, c.name.name, .{ .class = @enumFromInt(i) });
        }
        return out;
    }
};

fn valueSubject(env: *const core.env.Env, symbol: core.SymbolId, name: []const u8) Subject {
    switch (env.interner.details(symbol)) {
        .synonym => return .{ .synonym = name },
        .method => |m| return .{ .method = .{ .name = name, .class = m.class } },
        else => {},
    }
    const owner = datatypes.ownerOf(&env.interner, symbol) orelse return .{ .value = name };
    return .{ .constructor_of = owner };
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
