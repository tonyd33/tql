const std = @import("std");

const Allocator = std.mem.Allocator;

/// Implements an immutable map with O(1) space complexity growth on
/// copies, O(1) time complexity on copies and O(n) time complexity on
/// lookups.
pub fn OverlayMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pair: ?struct { // empty to make things like copies easier
            key: K,
            value: ?V, // null for holes
        },
        prev: ?*Self,
        ref_count: u16,

        pub fn init() Self {
            return Self{
                .pair = null,
                .prev = null,
                .ref_count = 0,
            };
        }

        pub fn create(gpa: Allocator) !*Self {
            const root = try gpa.create(Self);
            root.* = Self.init();
            return root;
        }

        fn propagate(self: *Self, gpa: Allocator, do_destroy: bool) void {
            if (self.ref_count > 0) {
                self.ref_count -= 1;
            }

            if (self.ref_count == 0) {
                const prev = self.prev;
                if (do_destroy) {
                    gpa.destroy(self);
                }
                if (prev) |p| {
                    p.propagate(gpa, do_destroy);
                }
            }
        }

        /// Destroy this node. Propagate only reference updates up the DAG.
        pub fn dereference(self: *Self, gpa: Allocator) void {
            if (self.ref_count == 0) {
                self.propagate(gpa, false);
                gpa.destroy(self);
            }
        }

        /// Destroy and propagate destruction up the DAG if applicable.
        /// This provides an easy interface to allow keeping track of only leaf nodes.
        pub fn destroy(self: *Self, gpa: Allocator) void {
            // Only leaf nodes can trigger destruction propagation
            if (self.ref_count == 0) {
                self.propagate(gpa, true);
            }
        }

        pub fn get(self: *const Self, key: K) ?V {
            var curr: ?*const Self = self;
            while (curr) |c| {
                if (c.pair) |p| {
                    if (p.key == key) {
                        return p.value;
                    }
                }
                curr = c.prev;
            }
            return null;
        }

        pub fn copy(self: *Self, gpa: Allocator) !*Self {
            const new_node = try gpa.create(Self);
            new_node.* = Self{
                .pair = null,
                .prev = self,
                .ref_count = 0,
            };
            self.ref_count += 1;
            return new_node;
        }

        /// As opposed to copy, clone will create a new environment such that
        /// destruction of this environment has no effect on the original
        /// environment.
        pub fn clone(self: *Self, gpa: Allocator) !*Self {
            // We should compactify the values while we're at it.
            // Using the snapshot is slightly inefficient, but a lot easier
            var map = try self.snapshot(gpa);
            defer map.deinit();

            // NOTE: Maybe we just back OverlayMaps with an optional real
            // hash map acting as the root...
            var new = try Self.create(gpa);
            var iterator = map.iterator();
            while (iterator.next()) |p| {
                new = try new.copyPut(gpa, p.key_ptr.*, p.value_ptr.*);
            }

            return new;
        }

        pub fn copyPut(self: *Self, gpa: Allocator, key: K, value: V) !*Self {
            const c = try self.copy(gpa);
            c.*.pair = .{ .key = key, .value = value };
            return c;
        }

        pub fn copyRemove(self: *Self, gpa: Allocator, key: K) !*Self {
            const c = try self.copy(gpa);
            c.*.pair = .{ .key = key, .value = null };
            return c;
        }

        /// Snapshots the overlay layers into a stable hash map
        pub fn snapshot(self: *const Self, gpa: Allocator) !std.AutoHashMap(K, V) {
            var map = std.AutoHashMap(K, V).init(gpa);
            errdefer map.deinit();

            // Track keys we've already seen (including holes)
            var seen = std.AutoHashMap(K, void).init(gpa);
            defer seen.deinit();

            // Traverse from current to root, collecting all keys
            // The first value encountered for each key is the most recent (overlay priority)
            var curr: ?*const Self = self;
            while (curr) |c| {
                if (c.pair) |p| {
                    // Check if we've already seen this key
                    const entry = try seen.getOrPut(p.key);
                    if (!entry.found_existing) {
                        // First time seeing this key - use this value if not a hole
                        if (p.value) |v| {
                            try map.put(p.key, v);
                        }
                        // If p.value is null, it's a hole - we mark it as seen but don't add to map
                    }
                }
                curr = c.prev;
            }

            return map;
        }
    };
}

const expect = std.testing.expect;

test "basic" {
    const allocator = std.testing.allocator;

    var om = try allocator.create(OverlayMap(u32, u32));
    om.* = .init();
    defer om.destroy(allocator);
    om = try om.copyPut(allocator, 6, 9);
    om = try om.copyPut(allocator, 4, 20);

    try expect(om.get(6) == 9);
    try expect(om.get(4) == 20);

    try expect(om.get(1) == null);
    try expect(om.get(2) == null);
}

test "hole" {
    const allocator = std.testing.allocator;

    var om = try allocator.create(OverlayMap(u32, u32));
    om.* = .init();
    defer om.destroy(allocator);
    om = try om.copyPut(allocator, 6, 9);
    om = try om.copyRemove(allocator, 6);
    om = try om.copyPut(allocator, 4, 20);

    try expect(om.get(6) == null);
    try expect(om.get(4) == 20);
}

test "overlay" {
    const allocator = std.testing.allocator;

    var om = try allocator.create(OverlayMap(u32, u32));
    om.* = .init();
    defer om.destroy(allocator);
    om = try om.copyPut(allocator, 6, 9);
    om = try om.copyPut(allocator, 4, 20);
    om = try om.copyPut(allocator, 6, 7);

    try expect(om.get(6) == 7);
    try expect(om.get(4) == 20);
}

test "destroy forked overlay" {
    const allocator = std.testing.allocator;

    const om_0 = try allocator.create(OverlayMap(u32, u32));
    om_0.* = .init();

    try expect(om_0.ref_count == 0);
    var om_1 = try om_0.copyPut(allocator, 1, 0);
    try expect(om_1.ref_count == 0);
    try expect(om_0.ref_count == 1);

    const om_2 = try om_1.copyPut(allocator, 2, 0);
    try expect(om_2.ref_count == 0);
    try expect(om_1.ref_count == 1);
    try expect(om_0.ref_count == 1);
    const om_3 = try om_1.copyPut(allocator, 3, 0);
    try expect(om_3.ref_count == 0);
    try expect(om_2.ref_count == 0);
    try expect(om_1.ref_count == 2);
    try expect(om_0.ref_count == 1);

    om_2.destroy(allocator);
    try expect(om_3.*.ref_count == 0);
    try expect(om_1.*.ref_count == 1);
    try expect(om_0.*.ref_count == 1);
    om_3.destroy(allocator);
}

test "destroy in middle" {
    const allocator = std.testing.allocator;

    var om_0 = try allocator.create(OverlayMap(u32, u32));
    om_0.* = .init();

    try expect(om_0.ref_count == 0);
    var om_1 = try om_0.copyPut(allocator, 1, 0);
    try expect(om_1.ref_count == 0);
    try expect(om_0.ref_count == 1);

    const om_2 = try om_1.copyPut(allocator, 2, 0);
    try expect(om_2.ref_count == 0);
    try expect(om_1.ref_count == 1);
    try expect(om_0.ref_count == 1);

    om_1.destroy(allocator);
    try expect(om_2.ref_count == 0);
    try expect(om_1.ref_count == 1);
    try expect(om_0.ref_count == 1);

    om_2.destroy(allocator);
}

test "snapshot" {
    const allocator = std.testing.allocator;

    var om = try allocator.create(OverlayMap(u32, u32));
    om.* = .init();
    defer om.destroy(allocator);

    // Build overlay with multiple layers
    om = try om.copyPut(allocator, 1, 10);
    om = try om.copyPut(allocator, 2, 20);
    om = try om.copyPut(allocator, 3, 30);

    // Override key 1 with new value
    om = try om.copyPut(allocator, 1, 100);

    // Remove key 2 (create hole)
    om = try om.copyRemove(allocator, 2);

    // Add key 4
    om = try om.copyPut(allocator, 4, 40);

    // Create snapshot
    var snapshot_map = try om.snapshot(allocator);
    defer snapshot_map.deinit();

    // Verify snapshot contents
    try expect(snapshot_map.get(1).? == 100); // Should have overridden value
    try expect(!snapshot_map.contains(2)); // Should be removed (hole)
    try expect(snapshot_map.get(3).? == 30); // Should be present
    try expect(snapshot_map.get(4).? == 40); // Should be present
    try expect(snapshot_map.count() == 3); // Only 3 keys (1, 3, 4)
}
