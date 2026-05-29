const std = @import("std");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// Bounded MPMC blocking queue backed by RingBuffer. Producers block when
/// full; consumers block when empty. Once `close()` is called and the queue
/// drains, `pop` returns `.closed`.
pub fn BlockingQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        buf: RingBuffer(T),
        mu: std.Io.Mutex = .init,
        cv: std.Io.Condition = .init,
        closed_flag: bool = false,

        pub const PopResult = union(enum) {
            value: T,
            timeout,
            closed,
        };

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
                        try self.cv.wait(self.io, &self.mu);
                        continue;
                    }
                    return err;
                };
                break;
            }
            self.cv.signal(self.io);
        }

        /// Block until a value is available or the queue is closed and drained.
        pub fn pop(self: *Self) !?T {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            while (true) {
                if (self.buf.pop()) |v| {
                    self.cv.signal(self.io);
                    return v;
                }
                if (self.closed_flag) return null;
                try self.cv.wait(self.io, &self.mu);
            }
        }

        /// Mark the queue closed and wake all blocked threads. Pending values
        /// remain poppable; subsequent pops after drain return `.closed`.
        pub fn close(self: *Self) !void {
            try self.mu.lock(self.io);
            self.closed_flag = true;
            self.cv.broadcast(self.io);
            self.mu.unlock(self.io);
        }
    };
}
