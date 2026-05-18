const std = @import("std");

pub fn ThreadSafe(comptime T: type) type {
    return struct {
        inner: T,
        mutex: std.Thread.Mutex = .{},

        const Self = @This();

        pub fn lock(self: *Self) LockedGuard {
            self.mutex.lock();
            return .{ .inner = &self.inner, .mutex = &self.mutex };
        }

        pub fn tryLock(self: *Self) ?LockedGuard {
            if (!self.mutex.tryLock()) return null;
            return .{ .inner = &self.inner, .mutex = &self.mutex };
        }

        pub const LockedGuard = struct {
            inner: *T,
            mutex: *std.Thread.Mutex,

            pub fn release(self: LockedGuard) void {
                self.mutex.unlock();
            }
        };
    };
}
