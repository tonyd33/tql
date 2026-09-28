const std = @import("std");
const core = @import("core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

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
        .name = "is_named",
        .scheme = .{ .type = try B.func(types.node_type, try B.boolType()) },
        .primop = .is_named,
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
    try out.append(gpa, .{
        .name = "is_kind",
        .scheme = .{ .type = try B.func(
            types.kind_type,
            try B.func(types.node_type, try B.boolType()),
        ) },
        .primop = .is_kind,
    });
    inline for (.{
        .{ "of_kind", PrimOp.of_kind },
        .{ "children_of_kind", PrimOp.children_of_kind },
        .{ "descendants_of_kind", PrimOp.descendants_of_kind },
    }) |row| {
        try out.append(gpa, .{
            .name = row[0],
            .scheme = .{ .type = try B.func(
                types.kind_type,
                try B.filter(types.node_type, types.node_type),
            ) },
            .primop = row[1],
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

    return switch (operator) {
        .eq, .ne => try comparisonScheme(B, .Eq),
        .lt, .lte, .gt, .gte => try comparisonScheme(B, .Ord),
        .match, .not_match => .{ .type = try B.func(
            types.string_type,
            try B.func(types.regex_type, try B.boolType()),
        ) },
        .add, .subtract, .multiply, .divide, .modulo => .{ .type = try B.func(
            types.int_type,
            try B.func(types.int_type, types.int_type),
        ) },
    };
}

/// `class a => a -> a -> Bool`.
fn comparisonScheme(B: Builder, class: types.TypeClassConstraint.Class) !types.Scheme {
    const a = types.variable_type(0);
    return .{
        .quantified = 1,
        .constraints = try B.arena.dupe(types.TypeClassConstraint, &.{
            .{ .class = class, .type = a },
        }),
        .type = try B.func(a, try B.func(a, try B.boolType())),
    };
}

/// Declares the structural types, then interns the primitives with their
/// schemes. Called once on a fresh environment, before any body is resolved,
/// so a declaration colliding with a primitive's name fails on intern.
pub fn populate(target: *core.env.Env) !void {
    const arena = target.allocator();
    try target.datatypes.reserveStructural(&target.interner);

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(target.gpa);
    try primitiveSchemes(arena, &target.datatypes, &rows, target.gpa);

    for (rows.items) |row| {
        const id = try target.interner.intern(row.name, .{ .primop = row.primop });
        try target.setScheme(id, row.scheme);
    }
}

/// An environment with the primitives already in it.
fn fixture(gpa: Allocator) !core.env.Env {
    var target = try core.env.Env.init(gpa);
    errdefer target.deinit();
    try populate(&target);
    return target;
}

test "primitives are the documented set" {
    // Held by hand against the language definition. A row added to one side and
    // not the other fails here rather than drifting silently.
    const expected = [_][]const u8{
        "text",      "kind",             "is_named",            "range",
        "length",    "toint",            "filename",            "parent",
        "ancestors", "children",         "descendants",         "is_kind",
        "of_kind",   "children_of_kind", "descendants_of_kind",
    };

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var declared = datatypes.Registry.init(arena.allocator());
    var interner = core.Interner.init(arena.allocator());
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
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    const text = target.interner.lookup("text") orelse return error.Missing;
    try std.testing.expectEqualStrings("text", target.interner.spelling(text));
    try std.testing.expectEqual(PrimOp.text, target.interner.details(text).primop);
    try std.testing.expect(target.schemeOf(text) != null);
}

test "a declaration colliding with a primitive's name is rejected" {
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    try std.testing.expectError(
        error.Collision,
        target.interner.intern("children", .vanilla),
    );
}

test "operator schemes take scalars, not filters" {
    const gpa = std.testing.allocator;
    var target = try fixture(gpa);
    defer target.deinit();
    const arena = target.allocator();

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    try (try operatorScheme(arena, &target.datatypes, .eq)).format(&buf.writer);
    try std.testing.expectEqualStrings("Eq a => a -> a -> Bool", buf.written());

    buf.clearRetainingCapacity();
    try (try operatorScheme(arena, &target.datatypes, .add)).format(&buf.writer);
    try std.testing.expectEqualStrings("Int -> Int -> Int", buf.written());

    // Every operator has one, so a new member fails here rather than at
    // evaluation.
    for (std.enums.values(Scalar)) |operator| {
        _ = try operatorScheme(arena, &target.datatypes, operator);
    }
}
