const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const runtime = @import("../runtime.zig");

pub const VariableTable = struct {
    map: std.StringHashMap(runtime.VariableId),

    pub fn init(allocator: Allocator) VariableTable {
        return .{
            .map = std.StringHashMap(runtime.VariableId).init(allocator),
        };
    }

    pub fn deinit(self: *VariableTable) void {
        self.map.deinit();
    }

    pub fn get(self: *const VariableTable, name: []const u8) ?runtime.VariableId {
        return self.map.get(name);
    }
};

pub const ScopeStack = struct {
    allocator: std.mem.Allocator,
    variable_tables: std.ArrayList(VariableTable),
    /// IDs are unique across the whole compile. Scopes only govern name → id
    /// lookup, not id allocation.
    next_id: runtime.VariableId,

    pub fn init(allocator: std.mem.Allocator) ScopeStack {
        return .{
            .allocator = allocator,
            .variable_tables = .empty,
            .next_id = 0,
        };
    }

    pub fn deinit(self: *ScopeStack) void {
        for (self.variable_tables.items) |*table| {
            table.deinit();
        }
        self.variable_tables.deinit(self.allocator);
    }

    pub fn enterScope(self: *ScopeStack) !void {
        try self.variable_tables.append(self.allocator, .init(self.allocator));
    }

    pub fn currentScope(self: *ScopeStack) !*VariableTable {
        const items = self.variable_tables.items;
        if (items.len == 0) return error.ProgrammerDumb;
        return &items[items.len - 1];
    }

    pub fn exitScope(self: *ScopeStack) void {
        var scope = self.variable_tables.pop();
        scope.?.deinit();
    }

    pub fn getOrPut(self: *ScopeStack, name: []const u8) error{
        OutOfMemory,
        ProgrammerDumb,
    }!runtime.VariableId {
        if (self.get(name)) |id| {
            return id;
        }
        const curr = try self.currentScope();
        const result = try curr.map.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = self.next_id;
            self.next_id += 1;
        }
        return result.value_ptr.*;
    }

    pub fn get(self: ScopeStack, name: []const u8) ?runtime.VariableId {
        var i = self.variable_tables.items.len;
        while (i > 0) {
            i -= 1;
            const curr = self.variable_tables.items[i];
            if (curr.get(name)) |id| {
                return id;
            }
        }
        return null;
    }

    pub fn allocateAnonymous(self: *ScopeStack) !runtime.VariableId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

const testing = std.testing;

test "ScopeStack: getOrPut creates new variables" {
    var stack = ScopeStack.init(testing.allocator);
    defer stack.deinit();
    try stack.enterScope();

    const id1 = try stack.getOrPut("@class");
    const id2 = try stack.getOrPut("@name");
    const id3 = try stack.getOrPut("@method");

    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id2);
    try testing.expectEqual(@as(runtime.VariableId, 2), id3);
}

test "ScopeStack: getOrPut returns existing variable" {
    var stack = ScopeStack.init(testing.allocator);
    defer stack.deinit();
    try stack.enterScope();

    const id1 = try stack.getOrPut("@class");
    const id2 = try stack.getOrPut("@class");
    const id3 = try stack.getOrPut("@name");
    const id4 = try stack.getOrPut("@class");

    try testing.expectEqual(id1, id2);
    try testing.expectEqual(id1, id4);
    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id3);
}

test "ScopeStack: get returns null for non-existent variable" {
    var stack = ScopeStack.init(testing.allocator);
    defer stack.deinit();
    try stack.enterScope();

    try testing.expectEqual(@as(?runtime.VariableId, null), stack.get("@class"));
}

test "ScopeStack: ids are globally unique across nested scopes" {
    var stack = ScopeStack.init(testing.allocator);
    defer stack.deinit();
    try stack.enterScope();

    const outer = try stack.getOrPut("@outer");
    try stack.enterScope();
    const inner = try stack.getOrPut("@inner");
    const outer_seen = stack.get("@outer").?;
    stack.exitScope();

    try testing.expect(outer != inner);
    try testing.expectEqual(outer, outer_seen);
    try testing.expectEqual(@as(?runtime.VariableId, null), stack.get("@inner"));
}
