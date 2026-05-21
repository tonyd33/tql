const std = @import("std");

const RingBufferError = error {
    RingBufferFull,
};

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        pop_idx: u16,
        push_offset: u16,
        size: u16,

        pub fn init(
            allocator: std.mem.Allocator,
            size: u16,
        ) !Self {
            return .{
                .pop_idx = 0,
                .push_offset = 0,
                .buf = try allocator.alloc(T, size),
                .size = size,
            };
        }

        pub fn push(self: *Self, value: T) !void {
            if (self.push_offset == self.size) {
                // IMPROVE: better error
                return error.RingBufferFull;
            }
            const idx = (self.pop_idx + self.push_offset) % self.size;
            self.buf[idx] = value;
            self.push_offset += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.push_offset == 0) {
                return null;
            }
            const value = self.buf[self.pop_idx];
            self.pop_idx = (self.pop_idx + 1) % self.size;
            self.push_offset -= 1;
            return value;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
            self.pop_idx = 0;
            self.push_offset = 0;
            self.size = 0;
        }
    };
}

test "ring buffer sanity check" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u8).init(allocator, 4);
    defer rb.deinit(allocator);

    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);

    try std.testing.expectEqual(rb.pop(), 1);
    try std.testing.expectEqual(rb.pop(), 2);
    try std.testing.expectEqual(rb.pop(), 3);
    try std.testing.expectEqual(rb.pop(), 4);
    try std.testing.expectEqual(rb.pop(), null);
}

test "ring buffer loop" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u8).init(allocator, 4);
    defer rb.deinit(allocator);

    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);

    try std.testing.expectEqual(rb.pop(), 1);
    try rb.push(5);

    try std.testing.expectEqual(rb.pop(), 2);
    try rb.push(6);

    try std.testing.expectEqual(rb.pop(), 3);
    try std.testing.expectEqual(rb.pop(), 4);
    try std.testing.expectEqual(rb.pop(), 5);
    try std.testing.expectEqual(rb.pop(), 6);
    try std.testing.expectEqual(rb.pop(), null);
}

test "ring buffer overflow" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u8).init(allocator, 4);
    defer rb.deinit(allocator);

    try rb.push(1);
    try rb.push(2);
    try rb.push(3);
    try rb.push(4);

    try std.testing.expectError(error.RingBufferFull, rb.push(5));
}
