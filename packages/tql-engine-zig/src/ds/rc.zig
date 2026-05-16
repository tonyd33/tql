const std = @import("std");
const Allocator = std.mem.Allocator;

/// Heap-allocated reference-counted cell. The cell itself is freed when the
/// refcount reaches zero. If `K` declares a `deinit` method (either
/// `deinit(*K) void` or `deinit(*K, Allocator) void`), it is invoked before
/// the cell is destroyed.
pub fn Rc(comptime K: type) type {
    return struct {
        const Self = @This();

        value: K,
        rc: u32,

        pub fn create(gpa: Allocator, value: K) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .value = value, .rc = 1 };
            return self;
        }

        pub fn reference(self: *Self) *Self {
            self.rc += 1;
            return self;
        }

        pub fn dereference(self: *Self, gpa: Allocator) void {
            std.debug.assert(self.rc > 0);
            self.rc -= 1;
            if (self.rc == 0) {
                if (comptime hasDeinit(K)) {
                    callDeinit(&self.value, gpa);
                }
                gpa.destroy(self);
            }
        }

        fn hasDeinit(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
                else => false,
            };
        }

        fn callDeinit(value: *K, gpa: Allocator) void {
            // this might kind of be overengineered
            const D = @TypeOf(K.deinit);
            const params = @typeInfo(D).@"fn".params;
            if (comptime params.len == 2) {
                value.deinit(gpa);
            } else {
                value.deinit();
            }
        }
    };
}

test "Rc trivial K" {
    const gpa = std.testing.allocator;
    const cell = try Rc(u32).create(gpa, 42);
    try std.testing.expectEqual(@as(u32, 42), cell.value);
    try std.testing.expectEqual(@as(u32, 1), cell.rc);
    _ = cell.reference();
    try std.testing.expectEqual(@as(u32, 2), cell.rc);
    cell.dereference(gpa);
    try std.testing.expectEqual(@as(u32, 1), cell.rc);
    cell.dereference(gpa);
}

test "Rc K with deinit(self)" {
    const Counter = struct {
        ptr: *u32,
        pub fn deinit(self: *@This()) void {
            self.ptr.* += 1;
        }
    };
    const gpa = std.testing.allocator;
    var calls: u32 = 0;
    const cell = try Rc(Counter).create(gpa, .{ .ptr = &calls });
    _ = cell.reference();
    cell.dereference(gpa);
    try std.testing.expectEqual(@as(u32, 0), calls);
    cell.dereference(gpa);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "Rc K with deinit(self, gpa)" {
    const Owned = struct {
        buf: []u8,
        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.buf);
        }
    };
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 8);
    const cell = try Rc(Owned).create(gpa, .{ .buf = buf });
    cell.dereference(gpa);
}
