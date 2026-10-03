const std = @import("std");
const core = @import("core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

const Scalar = core.Scalar;
const PrimOp = core.PrimOp;

/// The scheme of `primop`.
///
/// `[a]` and `Bool` are declared types, so a scheme mentioning either needs
/// the registry that declared them. Hence runtime rather than comptime.
fn schemeOf(B: Builder, primop: PrimOp) !types.Scheme {
    const a = types.variable_type(0);
    return switch (primop) {
        .text, .kind => .{ .type = try B.func(types.node_type, types.string_type) },
        .is_named => .{ .type = try B.func(types.node_type, try B.boolType()) },
        .range => .{ .type = try B.func(types.node_type, types.range_type) },
        .length => .{
            .quantified = 1,
            .constraints = try B.arena.dupe(types.TypeClassConstraint, &.{
                .{ .class = .Sized, .type = a },
            }),
            .type = try B.func(a, types.int_type),
        },
        .toint => .{ .type = try B.filter(types.string_type, types.int_type) },
        .filename => .{ .quantified = 1, .type = try B.filter(a, types.string_type) },
        .parent,
        .ancestors,
        .children,
        .named_children,
        .descendants,
        .named_descendants,
        => .{ .type = try B.filter(types.node_type, types.node_type) },
        .is_kind => .{ .type = try B.func(
            types.kind_type,
            try B.func(types.node_type, try B.boolType()),
        ) },
        .of_kind, .children_of_kind, .descendants_of_kind => .{ .type = try B.func(
            types.kind_type,
            try B.filter(types.node_type, types.node_type),
        ) },
    };
}

/// Type construction against one arena and registry.
const Builder = struct {
    arena: Allocator,
    declared: *const datatypes.Registry,

    fn func(self: Builder, from: types.Type, to: types.Type) !types.Type {
        return try types.func(self.arena, from, to);
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
    try target.datatypes.reserveStructural(&target.interner);

    const B = Builder{ .arena = target.allocator(), .declared = &target.datatypes };
    for (std.enums.values(PrimOp)) |primop| {
        const scheme = try schemeOf(B, primop);
        const id = try target.interner.intern(.prelude, @tagName(primop), .{ .primop = primop });
        try target.setScheme(id, scheme);
        target.primitives.set(primop, id);
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
        "text",                "kind",     "is_named",       "range",
        "length",              "toint",    "filename",       "parent",
        "ancestors",           "children", "named_children", "descendants",
        "named_descendants",   "is_kind",  "of_kind",        "children_of_kind",
        "descendants_of_kind",
    };

    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    var interned: usize = 0;
    for (std.enums.values(PrimOp)) |primop| {
        if (target.interner.lookup(.prelude, @tagName(primop)) != null) interned += 1;
    }
    try std.testing.expectEqual(expected.len, interned);
    for (expected) |name| {
        const id = target.interner.lookup(.prelude, name) orelse return error.Missing;
        try std.testing.expectEqualStrings(name, @tagName(target.interner.details(id).primop));
    }
}

test "every primitive is interned, and its scheme and primop are recorded" {
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    const text = target.interner.lookup(.prelude, "text") orelse return error.Missing;
    try std.testing.expectEqualStrings("text", target.interner.spelling(text));
    try std.testing.expectEqual(PrimOp.text, target.interner.details(text).primop);
    try std.testing.expect(target.schemeOf(text) != null);
}

test "a declaration colliding with a primitive's name is rejected" {
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    try std.testing.expectError(
        error.Collision,
        target.interner.intern(.prelude, "children", .vanilla),
    );
}

test "operator schemes take scalars, not filters" {
    const gpa = std.testing.allocator;
    var target = try fixture(gpa);
    defer target.deinit();
    const arena = target.allocator();

    try std.testing.expectFmt("Eq a => a -> a -> Bool", "{f}", .{try operatorScheme(arena, &target.datatypes, .eq)});

    try std.testing.expectFmt("Int -> Int -> Int", "{f}", .{try operatorScheme(arena, &target.datatypes, .add)});

    // Every operator has one, so a new member fails here rather than at
    // evaluation.
    for (std.enums.values(Scalar)) |operator| {
        _ = try operatorScheme(arena, &target.datatypes, operator);
    }
}
