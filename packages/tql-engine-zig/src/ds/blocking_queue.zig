const std = @import("std");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// Bounded MPMC blocking queue backed by RingBuffer. Producers block when
/// full; consumers block when empty. Once `close()` is called and the queue
/// drains, `pop` returns `.closed`.
pub fn BlockingQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: RingBuffer(T),
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        closed_flag: bool = false,

        pub const PopResult = union(enum) {
            value: T,
            timeout,
            closed,
        };

        pub fn init(allocator: std.mem.Allocator, size: u16) !Self {
            return .{ .buf = try RingBuffer(T).init(allocator, size) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.buf.deinit(allocator);
        }

        /// Block until pushed. Returns error only if a non-full buffer error
        /// occurs.
        pub fn push(self: *Self, value: T) !void {
            self.mu.lock();
            defer self.mu.unlock();
            while (true) {
                self.buf.push(value) catch |err| {
                    if (err == error.RingBufferFull) {
                        self.cv.wait(&self.mu);
                        continue;
                    }
                    return err;
                };
                break;
            }
            self.cv.signal();
        }

        /// Block until a value is available or the queue is closed and drained.
        pub fn pop(self: *Self) ?T {
            self.mu.lock();
            defer self.mu.unlock();
            while (true) {
                if (self.buf.pop()) |v| {
                    self.cv.signal();
                    return v;
                }
                if (self.closed_flag) return null;
                self.cv.wait(&self.mu);
            }
        }

        /// Mark the queue closed and wake all blocked threads. Pending values
        /// remain poppable; subsequent pops after drain return `.closed`.
        pub fn close(self: *Self) void {
            self.mu.lock();
            self.closed_flag = true;
            self.cv.broadcast();
            self.mu.unlock();
        }
    };
}
