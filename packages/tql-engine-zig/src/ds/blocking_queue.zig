const std = @import("std");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// Bounded MPMC blocking queue backed by RingBuffer. Producers block when
/// full; consumers block when empty. Once `close()` is called and the queue
/// drains, `pop` returns null.
pub fn BlockingQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        buf: RingBuffer(T),
        mu: std.Io.Mutex = .init,
        /// Waited on by producers only, so a signal always wakes a thread that
        /// can use the slot a pop freed.
        not_full: std.Io.Condition = .init,
        /// Waited on by consumers only.
        not_empty: std.Io.Condition = .init,
        closed_flag: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, size: u16) !Self {
            return .{
                .buf = try RingBuffer(T).init(allocator, size),
                .io = io,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.buf.deinit(allocator);
        }

        /// Block until pushed. Returns error only if a non-full buffer error
        /// occurs.
        pub fn push(self: *Self, value: T) !void {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            while (true) {
                self.buf.push(value) catch |err| {
                    if (err == error.RingBufferFull) {
                        try self.not_full.wait(self.io, &self.mu);
                        continue;
                    }
                    return err;
                };
                break;
            }
            self.not_empty.signal(self.io);
        }

        /// Block until a value is available or the queue is closed and drained.
        pub fn pop(self: *Self) !?T {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            while (true) {
                if (self.buf.pop()) |v| {
                    self.not_full.signal(self.io);
                    return v;
                }
                if (self.closed_flag) return null;
                try self.not_empty.wait(self.io, &self.mu);
            }
        }

        /// Mark the queue closed and wake all blocked threads. Pending values
        /// remain poppable; subsequent pops after drain return null.
        pub fn close(self: *Self) !void {
            try self.mu.lock(self.io);
            self.closed_flag = true;
            self.not_full.broadcast(self.io);
            self.not_empty.broadcast(self.io);
            self.mu.unlock(self.io);
        }
    };
}

test "every value pushed by many producers reaches some consumer" {
    const Queue = BlockingQueue(u32);
    const producers = 4;
    const consumers = 4;
    const per_producer = 2000;

    var queue = try Queue.init(std.testing.allocator, std.testing.io, 1);
    defer queue.deinit(std.testing.allocator);

    const Produce = struct {
        fn run(q: *Queue, base: u32) !void {
            var i: u32 = 0;
            while (i < per_producer) : (i += 1) try q.push(base + i);
        }
    };
    const Consume = struct {
        fn run(q: *Queue, sum: *u64) !void {
            while (try q.pop()) |v| sum.* += v;
        }
    };

    var sums: [consumers]u64 = @splat(0);
    var consuming: [consumers]std.Thread = undefined;
    for (&consuming, &sums) |*thread, *sum| {
        thread.* = try std.Thread.spawn(.{}, Consume.run, .{ &queue, sum });
    }
    var producing: [producers]std.Thread = undefined;
    for (&producing, 0..) |*thread, p| {
        const base: u32 = @intCast(p * per_producer);
        thread.* = try std.Thread.spawn(.{}, Produce.run, .{ &queue, base });
    }
    for (producing) |thread| thread.join();
    try queue.close();
    for (consuming) |thread| thread.join();

    var total: u64 = 0;
    for (sums) |s| total += s;
    const n = producers * per_producer;
    try std.testing.expectEqual(n * (n - 1) / 2, total);
}
