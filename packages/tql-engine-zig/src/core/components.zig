//! Strongly connected components of a reference graph.

const std = @import("std");

/// Tarjan's algorithm over a reference graph. Components come back in
/// dependency order: a component's callees precede it.
pub const Components = struct {
    allocator: std.mem.Allocator,
    groups: [][]u32,

    pub fn deinit(self: *Components) void {
        for (self.groups) |g| self.allocator.free(g);
        self.allocator.free(self.groups);
    }
};

/// `edges[i]` lists the nodes that node `i` references.
pub fn stronglyConnectedComponents(
    allocator: std.mem.Allocator,
    edges: []const []const u32,
) !Components {
    var state = try Tarjan.init(allocator, edges);
    defer state.deinit();

    for (0..edges.len) |i| {
        if (state.index[i] == Tarjan.unvisited) try state.strongConnect(@intCast(i));
    }

    return .{
        .allocator = allocator,
        .groups = try state.components.toOwnedSlice(allocator),
    };
}

/// Whether `members`, a strongly connected component of `edges`, has a cycle.
pub fn cyclic(members: []const u32, edges: []const []const u32) bool {
    return members.len > 1 or std.mem.indexOfScalar(u32, edges[members[0]], members[0]) != null;
}

const Tarjan = struct {
    const unvisited = std.math.maxInt(u32);

    allocator: std.mem.Allocator,
    edges: []const []const u32,
    index: []u32,
    lowlink: []u32,
    on_stack: []bool,
    stack: std.ArrayList(u32) = .empty,
    components: std.ArrayList([]u32) = .empty,
    next_index: u32 = 0,

    fn init(allocator: std.mem.Allocator, edges: []const []const u32) !Tarjan {
        const index = try allocator.alloc(u32, edges.len);
        errdefer allocator.free(index);
        const lowlink = try allocator.alloc(u32, edges.len);
        errdefer allocator.free(lowlink);
        const on_stack = try allocator.alloc(bool, edges.len);
        errdefer allocator.free(on_stack);

        @memset(index, unvisited);
        @memset(lowlink, 0);
        @memset(on_stack, false);

        return .{
            .allocator = allocator,
            .edges = edges,
            .index = index,
            .lowlink = lowlink,
            .on_stack = on_stack,
        };
    }

    fn deinit(self: *Tarjan) void {
        self.allocator.free(self.index);
        self.allocator.free(self.lowlink);
        self.allocator.free(self.on_stack);
        self.stack.deinit(self.allocator);
        for (self.components.items) |c| self.allocator.free(c);
        self.components.deinit(self.allocator);
    }

    fn strongConnect(self: *Tarjan, node: u32) !void {
        self.index[node] = self.next_index;
        self.lowlink[node] = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.allocator, node);
        self.on_stack[node] = true;

        for (self.edges[node]) |successor| {
            if (self.index[successor] == unvisited) {
                try self.strongConnect(successor);
                self.lowlink[node] = @min(self.lowlink[node], self.lowlink[successor]);
            } else if (self.on_stack[successor]) {
                self.lowlink[node] = @min(self.lowlink[node], self.index[successor]);
            }
        }

        if (self.lowlink[node] != self.index[node]) return;

        var component: std.ArrayList(u32) = .empty;
        errdefer component.deinit(self.allocator);
        while (true) {
            const member = self.stack.pop().?;
            self.on_stack[member] = false;
            try component.append(self.allocator, member);
            if (member == node) break;
        }
        std.mem.sortUnstable(u32, component.items, {}, std.sort.asc(u32));
        try self.components.append(self.allocator, try component.toOwnedSlice(self.allocator));
    }
};

test "a self-recursive definition is its own component" {
    const edges = [_][]const u32{&.{0}};
    var components_result = try stronglyConnectedComponents(std.testing.allocator, &edges);
    defer components_result.deinit();

    try std.testing.expectEqual(1, components_result.groups.len);
    try std.testing.expectEqualSlices(u32, &.{0}, components_result.groups[0]);
}

test "mutually recursive definitions share one component" {
    // 0 -> 1, 1 -> 0, and 2 -> 0. `is_even`/`is_odd` with a caller.
    const edges = [_][]const u32{ &.{1}, &.{0}, &.{0} };
    var components_result = try stronglyConnectedComponents(std.testing.allocator, &edges);
    defer components_result.deinit();

    try std.testing.expectEqual(2, components_result.groups.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, components_result.groups[0]);
    try std.testing.expectEqualSlices(u32, &.{2}, components_result.groups[1]);
}

test "independent definitions come back in dependency order" {
    // 0 references 1; 1 references nothing.
    const edges = [_][]const u32{ &.{1}, &.{} };
    var components_result = try stronglyConnectedComponents(std.testing.allocator, &edges);
    defer components_result.deinit();

    try std.testing.expectEqual(2, components_result.groups.len);
    try std.testing.expectEqualSlices(u32, &.{1}, components_result.groups[0]);
    try std.testing.expectEqualSlices(u32, &.{0}, components_result.groups[1]);
}
