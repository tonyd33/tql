const std = @import("std");

const Allocator = std.mem.Allocator;

// newtype SymbolId = u32
pub const SymbolId = enum(u32) { _ };

pub const InsertError = error{Collision} || Allocator.Error;

pub fn SymbolTable(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        entries: std.ArrayList(?T) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
        }

        pub fn get(self: *const Self, id: SymbolId) ?T {
            const index = @intFromEnum(id);
            if (index >= self.entries.items.len) return null;
            return self.entries.items[index];
        }

        pub fn put(self: *Self, id: SymbolId, value: T) Allocator.Error!void {
            const index = @intFromEnum(id);
            while (self.entries.items.len <= index) {
                try self.entries.append(self.allocator, null);
            }
            self.entries.items[index] = value;
        }
    };
}

/// Hands out symbol identities and enforces one-spelling-one-symbol among
/// globals.
pub const Interner = struct {
    allocator: Allocator,
    /// Heap-owned so this can be moved.
    arena: *std.heap.ArenaAllocator,
    /// Spelling per id, indexed by id. Locals are here too, so a diagnostic can
    /// name one; only globals enter `by_spelling`.
    spellings: std.ArrayList([]const u8) = .empty,
    by_spelling: std.StringHashMapUnmanaged(SymbolId) = .empty,

    pub fn init(allocator: Allocator) !Interner {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{ .allocator = allocator, .arena = arena };
    }

    pub fn deinit(self: *Interner) void {
        self.spellings.deinit(self.allocator);
        self.by_spelling.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    /// A global. Collides when the spelling is taken, which is what makes a
    /// redefinition an error rather than a shadowing.
    pub fn intern(self: *Interner, spelling_text: []const u8) InsertError!SymbolId {
        if (self.by_spelling.contains(spelling_text)) return error.Collision;
        return try self.internUnchecked(spelling_text);
    }

    /// Returns the existing id for a spelling, or interns it. Identical
    /// synthesis requests must yield one symbol. (e.g. `{a=1,b=2}` and
    /// `{b=2,a=1}` share a `record_filter[a,b]`)
    pub fn internOrGet(self: *Interner, spelling_text: []const u8) Allocator.Error!SymbolId {
        if (self.by_spelling.get(spelling_text)) |existing| return existing;
        return try self.internUnchecked(spelling_text);
    }

    fn internUnchecked(self: *Interner, spelling_text: []const u8) Allocator.Error!SymbolId {
        const owned = try self.arena.allocator().dupe(u8, spelling_text);
        const id = try self.append(owned);
        try self.by_spelling.put(self.allocator, owned, id);
        return id;
    }

    /// A local binder.
    pub fn fresh(self: *Interner, name: []const u8) Allocator.Error!SymbolId {
        return try self.append(try self.arena.allocator().dupe(u8, name));
    }

    fn append(self: *Interner, owned: []const u8) Allocator.Error!SymbolId {
        const id: SymbolId = @enumFromInt(self.spellings.items.len);
        try self.spellings.append(self.allocator, owned);
        return id;
    }

    pub fn lookup(self: *const Interner, name: []const u8) ?SymbolId {
        return self.by_spelling.get(name);
    }

    pub fn spelling(self: *const Interner, id: SymbolId) []const u8 {
        return self.spellings.items[@intFromEnum(id)];
    }

    pub fn count(self: *const Interner) usize {
        return self.spellings.items.len;
    }
};

test "internOrGet returns one symbol for one spelling" {
    var interner = try Interner.init(std.testing.allocator);
    defer interner.deinit();

    const first = try interner.internOrGet("is_kind[class_declaration]");
    const second = try interner.internOrGet("is_kind[class_declaration]");
    try std.testing.expectEqual(first, second);

    const other = try interner.internOrGet("is_kind[method_definition]");
    try std.testing.expect(first != other);
}

test "locals may share a name without colliding" {
    var interner = try Interner.init(std.testing.allocator);
    defer interner.deinit();

    const first = try interner.fresh("x");
    const second = try interner.fresh("x");
    try std.testing.expect(first != second);
    try std.testing.expectEqualStrings("x", interner.spelling(first));
}

test "a table is absent for ids its stage said nothing about" {
    var table = SymbolTable(u16).init(std.testing.allocator);
    defer table.deinit();

    const id: SymbolId = @enumFromInt(4);
    try std.testing.expectEqual(@as(?u16, null), table.get(id));
    try table.put(id, 7);
    try std.testing.expectEqual(@as(?u16, 7), table.get(id));
    try std.testing.expectEqual(@as(?u16, null), table.get(@enumFromInt(0)));
}
