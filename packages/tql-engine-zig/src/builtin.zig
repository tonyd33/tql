const std = @import("std");
const core = @import("core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

/// A scalar operator, which desugaring synthesizes an `op[...]` symbol for.
///
const Scalar = core.Scalar;
const PrimOp = core.PrimOp;

/// Builds the primitive schemes into `arena`.
///
/// `[a]` and `Bool` are declared types, so a scheme mentioning either needs
/// the registry that declared them. Hence runtime rather than comptime.
fn primitiveSchemes(
    arena: Allocator,
    declared: *const datatypes.Registry,
    out: *std.ArrayList(Row),
    gpa: Allocator,
) !void {
    const B = Builder{ .arena = arena, .declared = declared };

    const a = types.variable_type(0);

    try out.append(gpa, .{
        .name = "text",
        .scheme = .{ .type = try B.func(types.node_type, types.string_type) },
        .primop = .text,
    });
    try out.append(gpa, .{
        .name = "kind",
        .scheme = .{ .type = try B.func(types.node_type, types.string_type) },
        .primop = .kind,
    });
    try out.append(gpa, .{
        .name = "range",
        .scheme = .{ .type = try B.func(types.node_type, types.range_type) },
        .primop = .range,
    });
    try out.append(gpa, .{
        .name = "length",
        .scheme = .{
            .quantified = 1,
            .constraints = try arena.dupe(types.TypeClassConstraint, &.{
                .{ .class = .Sized, .type = a },
            }),
            .type = try B.func(a, types.int_type),
        },
        .primop = .length,
    });
    try out.append(gpa, .{
        .name = "toint",
        .scheme = .{ .type = try B.filter(types.string_type, types.int_type) },
        .primop = .toint,
    });
    try out.append(gpa, .{
        .name = "filename",
        .scheme = .{ .quantified = 1, .type = try B.filter(a, types.string_type) },
        .primop = .filename,
    });
    inline for (.{
        .{ "parent", PrimOp.parent },
        .{ "ancestors", PrimOp.ancestors },
        .{ "children", PrimOp.children },
        .{ "descendants", PrimOp.descendants },
    }) |axis| {
        try out.append(gpa, .{
            .name = axis[0],
            .scheme = .{ .type = try B.filter(types.node_type, types.node_type) },
            .primop = axis[1],
        });
    }
}

const Row = struct {
    name: []const u8,
    scheme: types.Scheme,
    primop: PrimOp,
};

/// Type construction against one arena and registry.
const Builder = struct {
    arena: Allocator,
    declared: *const datatypes.Registry,

    fn func(self: Builder, from: types.Type, to: types.Type) !types.Type {
        return try types.func(self.arena, from, to);
    }

    fn list(self: Builder, element: types.Type) !types.Type {
        return try self.declared.list(self.arena, element);
    }

    fn filter(self: Builder, input: types.Type, output: types.Type) !types.Type {
        return try self.declared.filter(self.arena, input, output);
    }

    fn boolType(self: Builder) !types.Type {
        return try self.declared.boolType(self.arena);
    }
};

/// The scheme of a scalar operator, built against `arena` and `declared`.
pub fn operatorScheme(
    arena: Allocator,
    declared: *const datatypes.Registry,
    operator: Scalar,
) !types.Scheme {
    const B = Builder{ .arena = arena, .declared = declared };
    const a = types.variable_type(0);

    const class: ?types.TypeClassConstraint.Class = switch (operator) {
        .eq, .ne => .Eq,
        .lt, .lte, .gt, .gte => .Ord,
        else => null,
    };

    if (class) |k| {
        return .{
            .quantified = 1,
            .constraints = try arena.dupe(types.TypeClassConstraint, &.{
                .{ .class = k, .type = a },
            }),
            .type = try B.func(a, try B.func(a, try B.boolType())),
        };
    }

    return switch (operator) {
        .match, .not_match => .{ .type = try B.func(
            types.string_type,
            try B.func(types.regex_type, try B.boolType()),
        ) },
        .add, .subtract, .multiply, .divide, .modulo => .{ .type = try B.func(
            types.int_type,
            try B.func(types.int_type, types.int_type),
        ) },
        .eq, .ne, .lt, .lte, .gt, .gte => unreachable,
    };
}

/// What each primitive is, keyed by the id it was interned as.
pub const Table = struct {
    schemes: core.SymbolTable(types.Scheme),
    primops: core.SymbolTable(PrimOp),

    pub fn deinit(self: *Table) void {
        self.schemes.deinit();
        self.primops.deinit();
    }

    pub fn scheme(self: *const Table, id: core.SymbolId) ?types.Scheme {
        return self.schemes.get(id);
    }

    pub fn primop(self: *const Table, id: core.SymbolId) ?PrimOp {
        return self.primops.get(id);
    }

    pub fn contains(self: *const Table, id: core.SymbolId) bool {
        return self.primops.get(id) != null;
    }
};

/// An interner with the primitives already interned, paired with the table
/// saying what they are. The two are created and destroyed together because the
/// ids in one only mean anything against the other.
pub const Interned = struct {
    interner: core.Interner,
    table: Table,
    datatypes: datatypes.Registry,

    /// Declares the structural types, then interns the primitives. Called
    /// once, before any body is resolved, so a declaration colliding with a
    /// primitive's name fails on intern.
    ///
    /// `arena` holds the schemes and must outlive the result.
    pub fn init(allocator: Allocator, arena: Allocator) !Interned {
        var interner = try core.Interner.init(allocator);
        errdefer interner.deinit();

        var declared = datatypes.Registry.init(allocator);
        errdefer declared.deinit();
        try declared.declareStructural(&interner, arena);

        var table: Table = .{
            .schemes = core.SymbolTable(types.Scheme).init(allocator),
            .primops = core.SymbolTable(PrimOp).init(allocator),
        };
        errdefer table.deinit();

        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(allocator);
        try primitiveSchemes(arena, &declared, &rows, allocator);

        for (rows.items) |row| {
            const id = try interner.intern(row.name);
            try table.schemes.put(id, row.scheme);
            try table.primops.put(id, row.primop);
        }
        return .{ .interner = interner, .table = table, .datatypes = declared };
    }

    pub fn deinit(self: *Interned) void {
        self.datatypes.deinit();
        self.table.deinit();
        self.interner.deinit();
    }
};

/// `Interned` plus the arena its schemes live in.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    interned: Interned,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .arena = .init(gpa), .interned = undefined };
        self.interned = try Interned.init(gpa, self.arena.allocator());
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.interned.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

test "primitives are the documented set" {
    // Held by hand against the language definition. A row added to one side and
    // not the other fails here rather than drifting silently.
    const expected = [_][]const u8{
        "text",     "kind",        "range",  "length",
        "toint",    "filename",    "parent", "ancestors",
        "children", "descendants",
    };

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var declared = datatypes.Registry.init(std.testing.allocator);
    defer declared.deinit();
    var interner = try core.Interner.init(std.testing.allocator);
    defer interner.deinit();
    try declared.declareStructural(&interner, arena.allocator());

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(std.testing.allocator);
    try primitiveSchemes(arena.allocator(), &declared, &rows, std.testing.allocator);

    try std.testing.expectEqual(expected.len, rows.items.len);
    for (expected, rows.items) |name, row| {
        try std.testing.expectEqualStrings(name, row.name);
    }
}

test "every primitive is interned, and its scheme and primop are recorded" {
    const gpa = std.testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);
    const interned = &fix.interned;

    const text = interned.interner.lookup("text") orelse return error.Missing;
    try std.testing.expectEqualStrings("text", interned.interner.spelling(text));
    try std.testing.expect(interned.table.contains(text));
    try std.testing.expectEqual(PrimOp.text, interned.table.primop(text).?);
    try std.testing.expect(interned.table.scheme(text) != null);
}

test "a declaration colliding with a primitive's name is rejected" {
    const gpa = std.testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try std.testing.expectError(error.Collision, fix.interned.interner.intern("children"));
}

test "operator schemes take scalars, not filters" {
    const gpa = std.testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);
    const arena = fix.arena.allocator();

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    try (try operatorScheme(arena, &fix.interned.datatypes, .eq)).format(&buf.writer);
    try std.testing.expectEqualStrings("Eq a => a -> a -> Bool", buf.written());

    buf.clearRetainingCapacity();
    try (try operatorScheme(arena, &fix.interned.datatypes, .add)).format(&buf.writer);
    try std.testing.expectEqualStrings("Int -> Int -> Int", buf.written());

    // Every operator has one, so a new member fails here rather than at
    // evaluation.
    for (std.enums.values(Scalar)) |operator| {
        _ = try operatorScheme(arena, &fix.interned.datatypes, operator);
    }
}
