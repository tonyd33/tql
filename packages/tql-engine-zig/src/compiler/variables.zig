const std = @import("std");
const Allocator = std.mem.Allocator;

const ir = @import("../ir.zig");
const VariableId = ir.VariableId;

pub const Namespace = struct {
    table: std.StringHashMap(VariableId),

    pub fn init(allocator: Allocator) Namespace {
        return .{ .table = std.StringHashMap(VariableId).init(allocator) };
    }

    pub fn deinit(self: *Namespace) void {
        self.table.deinit();
    }
};

pub const VariableTable = struct {
    allocator: Allocator,
    next_id: VariableId,
    names: std.AutoHashMap(VariableId, []const u8),

    pub fn init(allocator: Allocator) VariableTable {
        return .{
            .allocator = allocator,
            .next_id = 0,
            .names = std.AutoHashMap(VariableId, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *VariableTable) void {
        self.names.deinit();
    }

    pub fn newNamespace(self: *VariableTable) Namespace {
        return Namespace.init(self.allocator);
    }

    pub fn declare(self: *VariableTable, ns: *Namespace, name: []const u8) !VariableId {
        const result = try ns.table.getOrPut(name);
        if (result.found_existing) return result.value_ptr.*;

        const id = self.next_id;
        self.next_id += 1;
        result.value_ptr.* = id;
        try self.names.put(id, name);
        return id;
    }

    pub fn bind(self: *VariableTable, ns: *Namespace, name: []const u8, id: VariableId) !void {
        try ns.table.put(name, id);
        try self.names.put(id, name);
    }

    pub fn resolve(_: *VariableTable, ns: *const Namespace, name: []const u8) ?VariableId {
        return ns.table.get(name);
    }

    pub fn allocateAnonymous(self: *VariableTable) VariableId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn moveNames(self: *VariableTable) std.AutoHashMap(VariableId, []const u8) {
        return self.names.move();
    }
};
