//! Symbol interning and per-symbol side tables.

const std = @import("std");
// TODO: break this cycle. details.zig imports TypeId back from here.
const Details = @import("details.zig").Details;

const Allocator = std.mem.Allocator;

// newtype SymbolId = u32
pub const SymbolId = enum(u32) { _ };

// newtype TypeId = u32
pub const TypeId = enum(u32) { _ };

pub const InsertError = error{Collision} || Allocator.Error;

/// A symbol's identity and what it denotes.
pub const Symbol = struct {
    spelling: []const u8,
    details: Details,
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

/// Hands out symbol identities and enforces one-spelling-one-symbol among
/// globals.
///
/// Everything interned is allocated from `allocator` and freed with it.
pub const Interner = struct {
    allocator: Allocator,
    /// One entry per id, indexed by id. Locals are here too, so a diagnostic
    /// can name one; only globals enter `by_spelling`.
    entries: std.ArrayList(Symbol) = .empty,
    by_spelling: std.StringHashMapUnmanaged(SymbolId) = .empty,

    pub fn init(allocator: Allocator) Interner {
        return .{ .allocator = allocator };
    }

    /// A global. Collides when the spelling is taken, which is what makes a
    /// redefinition an error rather than a shadowing.
    pub fn intern(
        self: *Interner,
        spelling_text: []const u8,
        what: Details,
    ) InsertError!SymbolId {
        if (self.by_spelling.contains(spelling_text)) return error.Collision;
        return try self.internUnchecked(spelling_text, what);
    }

    /// Returns the existing id for a spelling, or interns it. Identical
    /// synthesis requests must yield one symbol. (e.g. `{a=1,b=2}` and
    /// `{b=2,a=1}` share a `record[a,b]`)
    pub fn internOrGet(
        self: *Interner,
        spelling_text: []const u8,
        what: Details,
    ) Allocator.Error!SymbolId {
        if (self.by_spelling.get(spelling_text)) |existing| return existing;
        return try self.internUnchecked(spelling_text, what);
    }

    fn internUnchecked(
        self: *Interner,
        spelling_text: []const u8,
        what: Details,
    ) Allocator.Error!SymbolId {
        const owned = try self.allocator.dupe(u8, spelling_text);
        const id = try self.append(owned, what);
        try self.by_spelling.put(self.allocator, owned, id);
        return id;
    }

    /// A local binder.
    pub fn fresh(self: *Interner, name: []const u8) Allocator.Error!SymbolId {
        return try self.append(try self.allocator.dupe(u8, name), .vanilla);
    }

    fn append(self: *Interner, owned: []const u8, what: Details) Allocator.Error!SymbolId {
        const id: SymbolId = @enumFromInt(self.entries.items.len);
        try self.entries.append(self.allocator, .{ .spelling = owned, .details = what });
        return id;
    }

    pub fn lookup(self: *const Interner, name: []const u8) ?SymbolId {
        return self.by_spelling.get(name);
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

    const what: Details = .{ .synthesized = .{ .kind_test = .{ .name = "k", .id = 1 } } };
    const first = try interner.internOrGet("is_kind[class_declaration]", what);
    const second = try interner.internOrGet("is_kind[class_declaration]", what);
    try std.testing.expectEqual(first, second);

    const other = try interner.internOrGet("is_kind[method_definition]", what);
    try std.testing.expect(first != other);
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
