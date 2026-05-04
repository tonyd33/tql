const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const runtime = @import("../runtime.zig");

pub const VariableTable = struct {
    map: std.StringHashMap(runtime.VariableId),
    next_id: runtime.VariableId,

    pub fn init(allocator: Allocator) VariableTable {
        return .{
            .map = std.StringHashMap(runtime.VariableId).init(allocator),
            .next_id = 0,
        };
    }

    pub fn deinit(self: *VariableTable) void {
        self.map.deinit();
    }

    pub fn clone(self: *VariableTable) error{OutOfMemory}!VariableTable {
        const map = try self.map.clone();
        return .{
            .map = map,
            .next_id = self.next_id,
        };
    }

    pub fn getOrPut(self: *VariableTable, name: []const u8) error{OutOfMemory}!runtime.VariableId {
        const result = try self.map.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = self.next_id;
            self.next_id += 1;
        }
        return result.value_ptr.*;
    }

    pub fn get(self: *const VariableTable, name: []const u8) ?runtime.VariableId {
        return self.map.get(name);
    }
};

const testing = std.testing;

test "VariableTable: getOrPut creates new variables" {
    var table = VariableTable.init(testing.allocator);
    defer table.deinit();

    const id1 = try table.getOrPut("@class");
    const id2 = try table.getOrPut("@name");
    const id3 = try table.getOrPut("@method");

    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id2);
    try testing.expectEqual(@as(runtime.VariableId, 2), id3);
}

test "VariableTable: getOrPut returns existing variable" {
    var table = VariableTable.init(testing.allocator);
    defer table.deinit();

    const id1 = try table.getOrPut("@class");
    const id2 = try table.getOrPut("@class");
    const id3 = try table.getOrPut("@name");
    const id4 = try table.getOrPut("@class");

    try testing.expectEqual(id1, id2);
    try testing.expectEqual(id1, id4);
    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id3);
}

test "VariableTable: get returns existing variable" {
    var table = VariableTable.init(testing.allocator);
    defer table.deinit();

    _ = try table.getOrPut("@class");
    _ = try table.getOrPut("@name");

    try testing.expectEqual(@as(runtime.VariableId, 0), table.get("@class").?);
    try testing.expectEqual(@as(runtime.VariableId, 1), table.get("@name").?);
}

test "VariableTable: get returns null for non-existent variable" {
    var table = VariableTable.init(testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(?runtime.VariableId, null), table.get("@class"));
}
