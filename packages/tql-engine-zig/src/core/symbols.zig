//! Symbol interning and per-symbol side tables.

const std = @import("std");
// TODO: break this cycle. details.zig imports TypeId back from here.
const Details = @import("details.zig").Details;

const Allocator = std.mem.Allocator;

// newtype SymbolId = u32
pub const SymbolId = enum(u32) { _ };

// newtype TypeId = u32
pub const TypeId = enum(u32) { _ };

/// A module of one link, in the order modules were declared.
pub const ModuleId = enum(u16) {
    prelude = 0,
    _,
};

pub const InsertError = error{Collision} || Allocator.Error;

/// A name as some module declares it. A synthesized symbol has no module.
pub const QualifiedName = struct {
    module: ?ModuleId,
    name: []const u8,

    pub fn Map(comptime V: type) type {
        return std.HashMapUnmanaged(QualifiedName, V, Context, std.hash_map.default_max_load_percentage);
    }

    pub const Context = struct {
        pub fn hash(_: Context, n: QualifiedName) u64 {
            var h = std.hash.Wyhash.init(0);
            const module: u32 = if (n.module) |m| @intFromEnum(m) else std.math.maxInt(u32);
            h.update(std.mem.asBytes(&module));
            h.update(n.name);
            return h.final();
        }

        pub fn eql(_: Context, a: QualifiedName, b: QualifiedName) bool {
            return a.module == b.module and std.mem.eql(u8, a.name, b.name);
        }
    };
};

/// A symbol's identity and what it denotes.
pub const Symbol = struct {
    spelling: []const u8,
    details: Details,
    /// The module that declares it. Null for a local or a synthesized symbol.
    module: ?ModuleId = null,
};

pub fn SymbolTable(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        entries: std.ArrayList(?T) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// A no-op when `allocator` is an arena.
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
        }

        pub fn get(self: *const Self, id: SymbolId) ?T {
            const index = @intFromEnum(id);
            if (index >= self.entries.items.len) return null;
            return self.entries.items[index];
        }

        pub fn reserve(self: *Self, len: usize) Allocator.Error!void {
            if (len <= self.entries.items.len) return;
            try self.entries.ensureTotalCapacityPrecise(self.allocator, len);
            self.entries.appendNTimesAssumeCapacity(null, len - self.entries.items.len);
        }

        pub fn put(self: *Self, id: SymbolId, value: T) Allocator.Error!void {
            const index = @intFromEnum(id);
            while (self.entries.items.len <= index) {
                try self.entries.append(self.allocator, null);
            }
            self.entries.items[index] = value;
        }

        pub const Entry = struct { id: SymbolId, value: T };

        /// Walks the symbols this table has a value for, in id order.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .entries = self.entries.items };
        }

        pub const Iterator = struct {
            entries: []const ?T,
            index: u32 = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.entries.len) {
                    const index = self.index;
                    self.index += 1;
                    if (self.entries[index]) |value| {
                        return .{ .id = @enumFromInt(index), .value = value };
                    }
                }
                return null;
            }
        };
    };
}

/// Hands out symbol identities and enforces one symbol per spelling within a
/// module.
///
/// Everything interned is allocated from `allocator` and freed with it.
pub const Interner = struct {
    allocator: Allocator,
    /// One entry per id, indexed by id. Locals are here too, so a diagnostic
    /// can name one; only globals enter `by_name`.
    entries: std.ArrayList(Symbol) = .empty,
    by_name: QualifiedName.Map(SymbolId) = .empty,
    /// Module names, indexed by `ModuleId`.
    modules: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: Allocator) Interner {
        return .{ .allocator = allocator };
    }

    /// Declares a module named `name`. Returns its id.
    pub fn declareModule(self: *Interner, name: []const u8) Allocator.Error!ModuleId {
        const id: ModuleId = @enumFromInt(self.modules.items.len);
        try self.modules.append(self.allocator, try self.allocator.dupe(u8, name));
        return id;
    }

    pub fn moduleName(self: *const Interner, id: ModuleId) []const u8 {
        return self.modules.items[@intFromEnum(id)];
    }

    /// A global declared by `module`. Collides when `module` already declares
    /// the spelling.
    pub fn intern(
        self: *Interner,
        module: ModuleId,
        spelling_text: []const u8,
        what: Details,
    ) InsertError!SymbolId {
        if (self.by_name.contains(.{ .module = module, .name = spelling_text })) return error.Collision;
        return try self.internUnchecked(module, spelling_text, what);
    }

    /// Returns the existing synthesized symbol for a spelling, or interns it.
    /// Identical synthesis requests must yield one symbol. (e.g. `{a=1,b=2}`
    /// and `{b=2,a=1}` share a `record[a,b]`)
    pub fn internOrGet(
        self: *Interner,
        spelling_text: []const u8,
        what: Details,
    ) Allocator.Error!SymbolId {
        if (self.by_name.get(.{ .module = null, .name = spelling_text })) |existing| return existing;
        return try self.internUnchecked(null, spelling_text, what);
    }

    fn internUnchecked(
        self: *Interner,
        module: ?ModuleId,
        spelling_text: []const u8,
        what: Details,
    ) Allocator.Error!SymbolId {
        const owned = try self.allocator.dupe(u8, spelling_text);
        const id = try self.append(.{ .spelling = owned, .details = what, .module = module });
        try self.by_name.put(self.allocator, .{ .module = module, .name = owned }, id);
        return id;
    }

    /// A local binder.
    pub fn fresh(self: *Interner, name: []const u8) Allocator.Error!SymbolId {
        return try self.append(.{ .spelling = try self.allocator.dupe(u8, name), .details = .vanilla });
    }

    fn append(self: *Interner, symbol: Symbol) Allocator.Error!SymbolId {
        const id: SymbolId = @enumFromInt(self.entries.items.len);
        try self.entries.append(self.allocator, symbol);
        return id;
    }

    /// The global `module` declares as `name`. A synthesized spelling has a
    /// null `module`.
    pub fn lookup(self: *const Interner, module: ?ModuleId, name: []const u8) ?SymbolId {
        return self.by_name.get(.{ .module = module, .name = name });
    }

    pub fn moduleOf(self: *const Interner, id: SymbolId) ?ModuleId {
        return self.entries.items[@intFromEnum(id)].module;
    }

    /// Whether `id` is a global: declared by a module, or synthesized.
    pub fn isGlobal(self: *const Interner, id: SymbolId) bool {
        const symbol = self.entries.items[@intFromEnum(id)];
        return symbol.module != null or symbol.details == .synthesized;
    }

    pub fn spelling(self: *const Interner, id: SymbolId) []const u8 {
        return self.entries.items[@intFromEnum(id)].spelling;
    }

    pub fn details(self: *const Interner, id: SymbolId) Details {
        return self.entries.items[@intFromEnum(id)].details;
    }

    /// Records what an already-interned symbol denotes. A constructor is
    /// interned before its datatype has an id, so its details arrive here.
    ///
    /// Preconditions: `id` was handed out by this interner.
    pub fn setDetails(self: *Interner, id: SymbolId, what: Details) void {
        self.entries.items[@intFromEnum(id)].details = what;
    }

    pub fn count(self: *const Interner) usize {
        return self.entries.items.len;
    }
};

test "internOrGet returns one symbol for one spelling" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interner = Interner.init(arena.allocator());

    const what: Details = .{ .synthesized = .{ .field = .{ .name = "f", .id = 1 } } };
    const first = try interner.internOrGet("field[name]", what);
    const second = try interner.internOrGet("field[name]", what);
    try std.testing.expectEqual(first, second);

    const other = try interner.internOrGet("field[body]", what);
    try std.testing.expect(first != other);
}

test "one spelling in two modules is two symbols" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interner = Interner.init(arena.allocator());

    const library: ModuleId = @enumFromInt(1);
    const prelude_filter = try interner.intern(.prelude, "filter", .vanilla);
    const library_filter = try interner.intern(library, "filter", .vanilla);
    try std.testing.expect(prelude_filter != library_filter);
    try std.testing.expectEqual(prelude_filter, interner.lookup(.prelude, "filter").?);
    try std.testing.expectEqual(library_filter, interner.lookup(library, "filter").?);
    try std.testing.expectEqual(library, interner.moduleOf(library_filter).?);
}

test "one spelling twice in one module collides" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interner = Interner.init(arena.allocator());

    _ = try interner.intern(.prelude, "filter", .vanilla);
    try std.testing.expectError(error.Collision, interner.intern(.prelude, "filter", .vanilla));
}

test "locals may share a name without colliding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interner = Interner.init(arena.allocator());

    const first = try interner.fresh("x");
    const second = try interner.fresh("x");
    try std.testing.expect(first != second);
    try std.testing.expectEqualStrings("x", interner.spelling(first));
}

test "a table is absent for ids its stage said nothing about" {
    var table = SymbolTable(u16).init(std.testing.allocator);
    defer table.deinit();

    const id: SymbolId = @enumFromInt(4);
    try std.testing.expectEqual(null, table.get(id));
    try table.put(id, 7);
    try std.testing.expectEqual(7, table.get(id));
    try std.testing.expectEqual(null, table.get(@enumFromInt(0)));
}
