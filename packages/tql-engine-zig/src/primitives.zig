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
    return switch (primop) {
        .text, .kind_name => .{ .type = try B.func(types.node_type, types.string_type) },
        .kind => .{ .type = try B.func(types.node_type, types.kind_type) },
        .is_named, .is_extra => .{ .type = try B.func(types.node_type, try B.boolType()) },
        .range => .{ .type = try B.func(types.node_type, types.range_type) },
        .string_length => .{ .type = try B.func(types.string_type, types.int_type) },
        .mod => .{ .type = try B.func(types.int_type, try B.func(types.int_type, types.int_type)) },
        .toint => .{ .type = try B.filter(types.string_type, types.int_type) },
        .filename => .{ .type = try B.filter(types.node_type, types.string_type) },
        .parent,
        .ancestors,
        .children,
        .named_children,
        .descendants,
        .named_descendants,
        => .{ .type = try B.filter(types.node_type, types.node_type) },
        .of_kind, .children_of_kind, .descendants_of_kind => .{ .type = try B.func(
            types.kind_type,
            try B.filter(types.node_type, types.node_type),
        ) },
        .is_kind => .{ .type = try B.func(types.kind_type, try B.func(types.node_type, try B.boolType())) },
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

    /// `a -> a -> result`.
    fn comparison(self: Builder, result: types.Type) !types.Scheme {
        const a = types.variable_type(0);
        return .{ .quantified = 1, .type = try self.func(a, try self.func(a, result)) };
    }
};

/// The scheme of a scalar operator, built against `arena` and `declared`.
pub fn operatorScheme(
    arena: Allocator,
    declared: *const datatypes.Registry,
    operator: Scalar,
) Allocator.Error!types.Scheme {
    const B = Builder{ .arena = arena, .declared = declared };

    return switch (operator) {
        .eq, .ne, .lt, .lte, .gt, .gte => try B.comparison(try B.boolType()),
        .compare => try B.comparison(try B.declared.orderingType(B.arena)),
        .match, .not_match => .{ .type = try B.func(
            types.string_type,
            try B.func(types.regex_type, try B.boolType()),
        ) },
        .add, .subtract, .multiply, .divide => .{ .type = try B.func(
            types.int_type,
            try B.func(types.int_type, types.int_type),
        ) },
    };
}

pub const max_record_fields = std.math.maxInt(types.TypeVar) - 1;

pub const SchemeError = error{TooManyRecordFields} || Allocator.Error;

/// The scheme of a synthesized symbol: `field[l]`, `op[+]`, `record[l,...]`
/// or `select[l]`, built against `arena` and `declared`.
pub fn synthesizedScheme(
    arena: Allocator,
    declared: *const datatypes.Registry,
    synthesized: core.Synthesized,
) SchemeError!types.Scheme {
    const B = Builder{ .arena = arena, .declared = declared };
    return switch (synthesized) {
        // The field id is resolved and threaded, and deliberately unused: a
        // field narrows the *value* but not yet the type.
        .field => .{ .type = try B.filter(types.node_type, types.node_type) },
        .operator => |operator| try operatorScheme(arena, declared, operator),
        .record => |labels| try recordScheme(arena, labels),
        .select => |label| try selectScheme(arena, label),
    };
}

/// `record[l_1,...,l_n] : t_1 -> ... -> t_n -> {l_1: t_1, ..., l_n: t_n}`.
///
/// The one scheme whose *shape* depends on its symbol's metadata rather than
/// its identity, so it is constructed per symbol with no table row. Quantifies
/// one variable per field.
fn recordScheme(arena: Allocator, labels: []const []const u8) SchemeError!types.Scheme {
    if (labels.len > max_record_fields) return error.TooManyRecordFields;

    const fields = try arena.alloc(types.Type.Field, labels.len);
    for (labels, fields, 0..) |label, *field, i| {
        field.* = .{
            .label = label,
            .type = try types.store(arena, types.variable_type(@intCast(i))),
        };
    }

    // Built right to left: the record is the innermost, each field type
    // wrapping it in one more arrow.
    var result: types.Type = .{ .record = .{ .fields = fields } };
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        result = try types.func(arena, types.variable_type(@intCast(i)), result);
    }

    return .{ .quantified = @intCast(labels.len), .type = result };
}

/// `select[l] : forall t r. {l: t | r} -> t`.
fn selectScheme(arena: Allocator, label: []const u8) Allocator.Error!types.Scheme {
    const field = types.variable_type(0);
    const fields = try arena.alloc(types.Type.Field, 1);
    fields[0] = .{ .label = label, .type = try types.store(arena, field) };
    const subject: types.Type = .{ .record = .{
        .fields = fields,
        .rest = try types.store(arena, types.variable_type(1)),
    } };
    return .{ .quantified = 2, .type = try types.func(arena, subject, field) };
}

/// Declares the built-in types, then interns the primitives with their
/// schemes. Called once on a fresh environment, before any body is resolved,
/// so a declaration colliding with a primitive's name fails on intern.
pub fn populate(target: *core.env.Env) !void {
    try target.datatypes.reserveBuiltins(&target.interner);

    const B = Builder{ .arena = target.allocator(), .declared = &target.datatypes };
    for (std.enums.values(PrimOp)) |primop| {
        const scheme = try schemeOf(B, primop);
        const id = try target.interner.intern(.prelude, primop.spelling(), .{ .primop = primop });
        try target.setScheme(id, scheme);
        target.primitives.set(primop, id);
    }
}

/// The synthesized symbol spelled `spelling`, interned as `what` with its
/// scheme on first use.
///
/// Preconditions:
/// - What `what` points to outlives `target`.
pub fn synthesizedSymbol(target: *core.env.Env, spelling: []const u8, what: core.Synthesized) SchemeError!core.SymbolId {
    const id = try target.interner.internOrGet(spelling, .{ .synthesized = what });
    if (target.schemeOf(id) == null) {
        try target.setScheme(id, try synthesizedScheme(target.allocator(), &target.datatypes, what));
    }
    return id;
}

/// The `op[...]` symbol of `scalar`, with its scheme.
pub fn operatorSymbol(target: *core.env.Env, scalar: Scalar) Allocator.Error!core.SymbolId {
    var buffer: [16]u8 = undefined;
    const spelling = std.fmt.bufPrint(&buffer, "op[{s}]", .{scalar.spelling()}) catch unreachable;
    return synthesizedSymbol(target, spelling, .{ .operator = scalar }) catch |err| switch (err) {
        error.TooManyRecordFields => unreachable,
        error.OutOfMemory => |e| return e,
    };
}

/// `select[label]`, reading the record field `label`, with its scheme.
pub fn selectSymbol(target: *core.env.Env, label: []const u8) Allocator.Error!core.SymbolId {
    const spelling = try std.fmt.allocPrint(target.gpa, "select[{s}]", .{label});
    defer target.gpa.free(spelling);
    if (target.interner.lookup(null, spelling)) |id| return id;
    const what: core.Synthesized = .{ .select = try target.allocator().dupe(u8, label) };
    return synthesizedSymbol(target, spelling, what) catch |err| switch (err) {
        error.TooManyRecordFields => unreachable,
        error.OutOfMemory => |e| return e,
    };
}

/// Declares the instances the machine implements at the primitive types.
///
/// Preconditions:
/// - `populate` has run on `target`.
pub fn declareInstances(target: *core.env.Env) !void {
    const equal = try operatorSymbol(target, .eq);
    const compare = try operatorSymbol(target, .compare);

    for ([_]types.Primitive{ .Int, .String, .Node, .Kind }) |p| {
        try declareInstance(target, .eq, p, &.{equal});
        try declareInstance(target, .serial, p, &.{});
    }
    for ([_]types.Primitive{ .Int, .String }) |p| try declareInstance(target, .ord, p, &.{compare});
}

/// An instance at `head` with no context, `methods` in class order.
fn declareInstance(
    target: *core.env.Env,
    class: core.classes.ClassId,
    head: types.Primitive,
    methods: []const core.SymbolId,
) !void {
    const arena = target.allocator();
    _ = (try target.declareInstance(.{
        .class = class,
        .head = .{ .primitive = head },
        .type = .{ .primitive = head },
        .context = &.{},
        .methods = try arena.dupe(core.SymbolId, methods),
        .dictionary = undefined,
        .module = .prelude,
    })).added;
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
        "%text",     "%kind",             "%kind_name",           "%is_named",
        "%is_extra", "%range",            "%string_length",       "%mod",
        "%toint",    "%filename",         "%parent",              "%ancestors",
        "%children", "%named_children",   "%descendants",         "%named_descendants",
        "%of_kind",  "%children_of_kind", "%descendants_of_kind", "%is_kind",
    };

    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    var interned: usize = 0;
    for (std.enums.values(PrimOp)) |primop| {
        if (target.interner.lookup(.prelude, primop.spelling()) != null) interned += 1;
    }
    try std.testing.expectEqual(expected.len, interned);
    for (expected) |name| {
        const id = target.interner.lookup(.prelude, name) orelse return error.Missing;
        try std.testing.expectEqualStrings(name, target.interner.details(id).primop.spelling());
    }
}

test "every primitive is interned, and its scheme and primop are recorded" {
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    const text = target.interner.lookup(.prelude, "%text") orelse return error.Missing;
    try std.testing.expectEqualStrings("%text", target.interner.spelling(text));
    try std.testing.expectEqual(PrimOp.text, target.interner.details(text).primop);
    try std.testing.expect(target.schemeOf(text) != null);
}

test "a declaration colliding with a primitive's name is rejected" {
    var target = try fixture(std.testing.allocator);
    defer target.deinit();

    try std.testing.expectError(
        error.Collision,
        target.interner.intern(.prelude, "%children", .vanilla),
    );
}

test "operator schemes take scalars, not filters" {
    const gpa = std.testing.allocator;
    var target = try fixture(gpa);
    defer target.deinit();
    const arena = target.allocator();

    try std.testing.expectFmt("a -> a -> Bool", "{f}", .{(try operatorScheme(arena, &target.datatypes, .eq)).named(&target.classes)});

    try std.testing.expectFmt("Int -> Int -> Int", "{f}", .{(try operatorScheme(arena, &target.datatypes, .add)).named(&target.classes)});

    // Every operator has one, so a new member fails here rather than at
    // evaluation.
    for (std.enums.values(Scalar)) |operator| {
        _ = try operatorScheme(arena, &target.datatypes, operator);
    }
}
