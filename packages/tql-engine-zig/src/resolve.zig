//! Scopes, declaration collection, and SCC computation.
//!
//! Declaration heads and signatures are collected before any body is resolved,
//! so forward references are valid. Bodies resolve lexically first, then
//! globally.

const std = @import("std");
const cst = @import("cst.zig");
const diagnostic = @import("diagnostic.zig");
const symbols = @import("symbols.zig");

/// A lexical scope chain. Each frame is one binding construct: lambda
/// parameters, a `let` group, a `do` bind, or a `do`-local `let` group.
pub const Scope = struct {
    parent: ?*const Scope,
    names: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        symbol: symbols.SymbolId,
    };

    pub fn lookup(self: *const Scope, name: []const u8) ?symbols.SymbolId {
        var frame: ?*const Scope = self;
        while (frame) |f| : (frame = f.parent) {
            // Later entries in a frame shadow earlier ones, which matters for
            // `\x x -> e`.
            var i = f.names.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, f.names[i].name, name)) return f.names[i].symbol;
            }
        }
        return null;
    }
};

/// A collected top-level declaration: the definition, its symbol, and the
/// signature that annotates it, if any.
pub const Declaration = struct {
    name: []const u8,
    symbol: symbols.SymbolId,
    definition: *const cst.Definition,
    signature: ?*const cst.Signature = null,
};

pub const Declarations = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Declaration) = .empty,

    pub fn deinit(self: *Declarations) void {
        self.items.deinit(self.allocator);
    }

    pub fn find(self: *const Declarations, name: []const u8) ?*const Declaration {
        for (self.items.items) |*d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn indexOf(self: *const Declarations, symbol: symbols.SymbolId) ?u32 {
        for (self.items.items, 0..) |d, i| {
            if (d.symbol == symbol) return @intCast(i);
        }
        return null;
    }
};

/// Walks declarations, interning each head and pairing
/// signatures with definitions. Every problem found is reported; collection
/// continues so one run reports them all.
pub fn collect(
    allocator: std.mem.Allocator,
    interner: *symbols.Interner,
    source: cst.SourceFile,
    sink: *diagnostic.Sink,
) !Declarations {
    var declarations: Declarations = .{ .allocator = allocator };
    errdefer declarations.deinit();

    // Captured by pointer into the array: iterating by value would copy the
    // element, and a pointer into that copy dies with the iteration.
    for (source.declarations) |*decl| {
        if (decl.* != .definition) continue;
        const definition = &decl.definition;

        if (declarations.find(definition.name)) |_| {
            try sink.report(
                .duplicate_definition,
                definition.span,
                "`{s}` is defined more than once",
                .{definition.name},
            );
            continue;
        }

        const symbol = interner.intern(definition.name) catch |err| switch (err) {
            error.Collision => {
                try sink.report(
                    .symbol_collision,
                    definition.span,
                    "`{s}` collides with an existing symbol",
                    .{definition.name},
                );
                continue;
            },
            else => |e| return e,
        };

        try declarations.items.append(allocator, .{
            .name = definition.name,
            .symbol = symbol,
            .definition = definition,
        });
    }

    for (source.declarations) |*decl| {
        if (decl.* != .signature) continue;
        const signature = &decl.signature;

        const target = for (declarations.items.items) |*d| {
            if (std.mem.eql(u8, d.name, signature.name)) break d;
        } else {
            // A signature naming a symbol registered before this file was
            // collected — a built-in, or a definition from a module linked
            // beneath it — is a collision rather than an orphan: the name is
            // taken, not merely undefined.
            if (interner.lookup(signature.name)) |_| {
                try sink.report(
                    .symbol_collision,
                    signature.span,
                    "`{s}` collides with an existing symbol",
                    .{signature.name},
                );
                continue;
            }
            try sink.report(
                .orphan_signature,
                signature.span,
                "`{s}` has a signature but no definition",
                .{signature.name},
            );
            continue;
        };

        if (target.signature != null) {
            try sink.report(
                .duplicate_signature,
                signature.span,
                "`{s}` has more than one signature",
                .{signature.name},
            );
            continue;
        }
        target.signature = signature;
    }

    return declarations;
}

/// Tarjan's algorithm over the global reference graph. Components come back in
/// dependency order: a component's callees precede it.
pub const Components = struct {
    allocator: std.mem.Allocator,
    groups: [][]u32,

    pub fn deinit(self: *Components) void {
        for (self.groups) |g| self.allocator.free(g);
        self.allocator.free(self.groups);
    }
};

/// `edges[i]` lists the declaration indices that declaration `i` references.
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

test "scopes resolve innermost first" {
    var interner = try symbols.Interner.init(std.testing.allocator);
    defer interner.deinit();

    const outer_x = try interner.fresh("x");
    const inner_x = try interner.fresh("x");

    const outer: Scope = .{ .parent = null, .names = &.{.{ .name = "x", .symbol = outer_x }} };
    const inner: Scope = .{ .parent = &outer, .names = &.{.{ .name = "x", .symbol = inner_x }} };

    try std.testing.expectEqual(inner_x, inner.lookup("x").?);
    try std.testing.expectEqual(outer_x, outer.lookup("x").?);
    try std.testing.expectEqual(null, inner.lookup("y"));
}

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
