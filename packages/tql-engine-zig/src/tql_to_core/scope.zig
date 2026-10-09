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
    primitive: core.types.Primitive,
    class: classes.ClassId,
};

pub const Filter = cst.Filter;

/// What a filter is asked to admit.
const Subject = union(enum) {
    value: []const u8,
    type: []const u8,
    /// A constructor, admitted only through `T(..)` for its type.
    constructors_of: []const u8,
    /// A method, admitted by its own name or through `C(..)` for its class.
    method: struct { name: []const u8, class: []const u8 },
    synonym: []const u8,
    /// A primitive, which no module exports.
    primitive,

    fn of(item: cst.Item) Subject {
        return switch (item.kind) {
            .value => .{ .value = item.name },
            .type, .type_and_constructors => .{ .type = item.name },
            .synonym => .{ .synonym = item.name },
        };
    }
};

fn admits(filter: Filter, subject: Subject) bool {
    if (subject == .primitive) return false;
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
            .type => |name| (item.kind == .type or item.kind == .type_and_constructors) and std.mem.eql(u8, item.name, name),
            .constructors_of => |name| item.kind == .type_and_constructors and std.mem.eql(u8, item.name, name),
            .method => |m| (item.kind == .value and std.mem.eql(u8, item.name, m.name)) or
                (item.kind == .type_and_constructors and std.mem.eql(u8, item.name, m.class)),
            .synonym => |name| item.kind == .synonym and std.mem.eql(u8, item.name, name),
            .primitive => false,
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
    classes: *const classes.Registry,

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

    pub fn declaredType(self: *const ModuleScope, module: ModuleId, name: []const u8) ?TypeName {
        if (self.datatypes.lookup(module, name)) |id| return .{ .datatype = id };
        if (self.datatypes.aliasNamed(module, name)) |alias| return .{ .alias = alias };
        if (self.datatypes.primitiveNamed(module, name)) |p| return .{ .primitive = p };
        if (self.classes.lookup(module, name)) |id| return .{ .class = id };
        return null;
    }

    fn valueSubject(self: *const ModuleScope, symbol: core.SymbolId, name: []const u8) Subject {
        switch (self.interner.details(symbol)) {
            .synonym => return .{ .synonym = name },
            .primop, .pseudo => return .primitive,
            .method => |m| return .{ .method = .{ .name = name, .class = self.classes.spelling(m.class) } },
            else => {},
        }
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
        const declared = switch (item.kind) {
            .value => if (self.interner.lookup(module, item.name)) |symbol|
                datatypes.ownerOf(self.interner, symbol) == null and admits(exports, self.valueSubject(symbol, item.name))
            else
                false,
            .type, .type_and_constructors => admits(exports, Subject.of(item)) and
                declaredType(self, module, item.name) != null,
            .synonym => if (self.interner.lookup(module, item.name)) |symbol|
                admits(exports, Subject.of(item)) and self.interner.details(symbol) == .synonym
            else
                false,
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
        const noun = switch (declaredType(self, module, item.name).?) {
            .datatype => "constructors",
            .class => "methods",
            .alias => {
                try sink.report(.unresolved_name, item.span, "`{s}` is an alias and has no constructors", .{item.name});
                return false;
            },
            .primitive => {
                try sink.report(.unresolved_name, item.span, "`{s}` is a primitive type and has no constructors", .{item.name});
                return false;
            },
        };
        if (admits(exports, .{ .constructors_of = item.name })) return true;
        try sink.report(
            .unresolved_name,
            item.span,
            "`{s}` does not export the {s} of `{s}`",
            .{ self.interner.moduleName(module), noun, item.name },
        );
        return false;
    }
};

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
