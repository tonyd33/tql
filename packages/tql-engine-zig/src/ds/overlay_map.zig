const std = @import("std");
const Rc = @import("rc.zig").Rc;

const Allocator = std.mem.Allocator;

/// Implements an immutable map with O(1) copy and O(n) lookup.
/// Each layer is a node owned by an `Rc`.
/// `Cell` is a thin by-value handle that exposes the ergonomic
/// method API; multiple handles to the same node each own one refcount.
///
/// If `K`/`V` declare `deinit`, stored entries are deinitialized when their
/// owning layer drops to zero references.
pub fn OverlayMap(comptime K: type, comptime V: type) type {
    return struct {
        pub const Node = struct {
            pair: ?struct { // empty to make things like copies easier
                key: K,
                value: ?V, // null for holes
            },
            prev: ?Cell,

            pub fn deinit(self: *Node, gpa: Allocator) void {
                if (self.pair) |*p| {
                    if (p.value) |*v| {
                        if (comptime hasDeinit(V)) deinitOne(v, gpa);
                    }
                    if (comptime hasDeinit(K)) deinitOne(&p.key, gpa);
                }
                if (self.prev) |prev| prev.dereference(gpa);
            }
        };

        pub const Cell = struct {
            inner: *Rc(Node),

            pub fn create(gpa: Allocator) !Cell {
                const inner = try Rc(Node).create(gpa, .{ .pair = null, .prev = null });
                return .{ .inner = inner };
            }

            pub fn reference(self: Cell) Cell {
                _ = self.inner.reference();
                return self;
            }

            pub fn dereference(self: Cell, gpa: Allocator) void {
                self.inner.dereference(gpa);
            }

            pub fn rc(self: Cell) u32 {
                return self.inner.rc;
            }

            pub fn copy(self: Cell, gpa: Allocator) !Cell {
                const inner = try Rc(Node).create(gpa, .{
                    .pair = null,
                    .prev = self.reference(),
                });
                return .{ .inner = inner };
            }

            pub fn copyPut(self: Cell, gpa: Allocator, key: K, value: V) !Cell {
                const child = try self.copy(gpa);
                child.inner.value.pair = .{ .key = key, .value = value };
                return child;
            }

            pub fn copyRemove(self: Cell, gpa: Allocator, key: K) !Cell {
                const child = try self.copy(gpa);
                child.inner.value.pair = .{ .key = key, .value = null };
                return child;
            }

            pub fn get(self: Cell, key: K) ?V {
                var curr: ?Cell = self;
                while (curr) |c| {
                    if (c.inner.value.pair) |p| {
                        if (p.key == key) return p.value;
                    }
                    curr = c.inner.value.prev;
                }
                return null;
            }

            pub fn snapshot(self: Cell, gpa: Allocator) !std.AutoHashMap(K, V) {
                var map = std.AutoHashMap(K, V).init(gpa);
                errdefer map.deinit();

                var seen = std.AutoHashMap(K, void).init(gpa);
                defer seen.deinit();

                var curr: ?Cell = self;
                while (curr) |c| {
                    if (c.inner.value.pair) |p| {
                        const entry = try seen.getOrPut(p.key);
                        if (!entry.found_existing) {
                            if (p.value) |v| try map.put(p.key, v);
                        }
                    }
                    curr = c.inner.value.prev;
                }
                return map;
            }
        };
    };
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

fn deinitOne(value: anytype, gpa: Allocator) void {
    const T = @TypeOf(value.*);
    const D = @TypeOf(T.deinit);
    const params = @typeInfo(D).@"fn".params;
    if (comptime params.len == 2) {
        value.deinit(gpa);
    } else {
        value.deinit();
    }
}

const expect = std.testing.expect;
const testing = std.testing;

test "basic" {
    const gpa = testing.allocator;
    const M = OverlayMap(u32, u32);

    var om = try M.Cell.create(gpa);
    {
        const n = try om.copyPut(gpa, 6, 9);
        om.dereference(gpa);
        om = n;
    }
    {
        const n = try om.copyPut(gpa, 4, 20);
        om.dereference(gpa);
        om = n;
    }
    defer om.dereference(gpa);

    try expect(om.get(6) == 9);
    try expect(om.get(4) == 20);
    try expect(om.get(1) == null);
}

test "hole" {
    const gpa = testing.allocator;
    const M = OverlayMap(u32, u32);

    var om = try M.Cell.create(gpa);
    {
        const n = try om.copyPut(gpa, 6, 9);
        om.dereference(gpa);
        om = n;
    }
    {
        const n = try om.copyRemove(gpa, 6);
        om.dereference(gpa);
        om = n;
    }
    {
        const n = try om.copyPut(gpa, 4, 20);
        om.dereference(gpa);
        om = n;
    }
    defer om.dereference(gpa);

    try expect(om.get(6) == null);
    try expect(om.get(4) == 20);
}

test "overlay" {
    const gpa = testing.allocator;
    const M = OverlayMap(u32, u32);

    var om = try M.Cell.create(gpa);
    inline for (.{ .{ 6, 9 }, .{ 4, 20 }, .{ 6, 7 } }) |pair| {
        const n = try om.copyPut(gpa, pair[0], pair[1]);
        om.dereference(gpa);
        om = n;
    }
    defer om.dereference(gpa);

    try expect(om.get(6) == 7);
    try expect(om.get(4) == 20);
}

test "fork: shared parent stays alive" {
    const gpa = testing.allocator;
    const M = OverlayMap(u32, u32);

    const om_0 = try M.Cell.create(gpa);
    try expect(om_0.rc() == 1);

    const om_1 = try om_0.copyPut(gpa, 1, 0);
    try expect(om_1.rc() == 1);
    try expect(om_0.rc() == 2);

    const om_2 = try om_1.copyPut(gpa, 2, 0);
    const om_3 = try om_1.copyPut(gpa, 3, 0);
    try expect(om_1.rc() == 3);

    om_2.dereference(gpa);
    try expect(om_1.rc() == 2);
    om_3.dereference(gpa);
    try expect(om_1.rc() == 1);

    om_1.dereference(gpa);
    try expect(om_0.rc() == 1);
    om_0.dereference(gpa);
}

test "snapshot" {
    const gpa = testing.allocator;
    const M = OverlayMap(u32, u32);

    var om = try M.Cell.create(gpa);
    const Step = struct { k: u32, v: ?u32 };
    const steps = [_]Step{
        .{ .k = 1, .v = 10 },
        .{ .k = 2, .v = 20 },
        .{ .k = 3, .v = 30 },
        .{ .k = 1, .v = 100 },
        .{ .k = 2, .v = null },
        .{ .k = 4, .v = 40 },
    };
    for (steps) |s| {
        const n = if (s.v) |v|
            try om.copyPut(gpa, s.k, v)
        else
            try om.copyRemove(gpa, s.k);
        om.dereference(gpa);
        om = n;
    }
    defer om.dereference(gpa);

    var snap = try om.snapshot(gpa);
    defer snap.deinit();

    try expect(snap.get(1).? == 100);
    try expect(!snap.contains(2));
    try expect(snap.get(3).? == 30);
    try expect(snap.get(4).? == 40);
    try expect(snap.count() == 3);
}

test "V with deinit fires once per layer drop" {
    const gpa = testing.allocator;
    const Counter = struct {
        ptr: *u32,
        pub fn deinit(self: *@This()) void {
            self.ptr.* += 1;
        }
    };
    const M = OverlayMap(u32, Counter);

    var calls: u32 = 0;
    var om = try M.Cell.create(gpa);
    {
        const n = try om.copyPut(gpa, 1, .{ .ptr = &calls });
        om.dereference(gpa);
        om = n;
    }
    {
        const n = try om.copyPut(gpa, 2, .{ .ptr = &calls });
        om.dereference(gpa);
        om = n;
    }
    try expect(calls == 0);
    om.dereference(gpa);
    try expect(calls == 2);
}
