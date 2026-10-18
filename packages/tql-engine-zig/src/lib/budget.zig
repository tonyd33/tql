//! A cap on the scratch one run may allocate.

const std = @import("std");

/// Refuse allocations once `limit` bytes have gone through it. Freed bytes
/// are not refunded. Not thread-safe.
pub const ScratchBudget = struct {
    child: std.mem.Allocator,
    limit: usize,
    spent: usize = 0,

    pub fn allocator(self: *ScratchBudget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// Charge the growth from `old_len` to `new_len`, or return false if it
    /// would pass the limit.
    fn charge(self: *ScratchBudget, old_len: usize, new_len: usize) bool {
        if (new_len <= old_len) return true;
        if (new_len - old_len > self.limit - self.spent) return false;
        self.spent += new_len - old_len;
        return true;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(0, len)) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(memory.len, new_len)) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(memory.len, new_len)) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "a scratch budget refuses what would pass its limit" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    const a = try gpa.alloc(u8, 60);
    defer gpa.free(a);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 41));
    const b = try gpa.alloc(u8, 40);
    defer gpa.free(b);
    try std.testing.expectEqual(100, budget.spent);
}

test "a scratch budget does not refund freed bytes" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    gpa.free(try gpa.alloc(u8, 60));
    try std.testing.expectEqual(60, budget.spent);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 41));
}

test "a scratch budget charges growth and not shrinking" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    var memory = try gpa.alloc(u8, 50);
    defer gpa.free(memory);
    try std.testing.expect(!gpa.resize(memory, 101));
    try std.testing.expectEqual(50, budget.spent);
    if (gpa.resize(memory, 10)) memory = memory[0..10];
    try std.testing.expectEqual(50, budget.spent);
}
