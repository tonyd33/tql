const std = @import("std");
const core = @import("core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

const Scalar = core.Scalar;
const PrimOp = core.PrimOp;
const Pseudo = core.Pseudo;

/// The scheme of `primop`.
///
/// `[a]` and `Bool` are declared types, so a scheme mentioning either needs
/// the registry that declared them. Hence runtime rather than comptime.
fn schemeOf(B: Builder, primop: PrimOp) !types.Scheme {
    return switch (primop) {
        .text => .{ .type = try B.func(types.node_type, types.string_type) },
        .kind => .{ .type = try B.func(types.node_type, types.kind_type) },
        .kind_spelling => .{ .type = try B.func(types.kind_type, types.string_type) },
        .is_named, .is_extra, .is_error, .is_missing, .has_error => .{ .type = try B.func(types.node_type, try B.boolType()) },
        .range => .{ .type = try B.func(types.node_type, types.range_type) },
        .string_length => .{ .type = try B.func(types.string_type, types.int_type) },
        .div, .mod, .quot, .rem => .{ .type = try B.func(types.int_type, try B.func(types.int_type, types.int_type)) },
        .toint => .{ .type = try B.func(types.string_type, try B.declared.maybe(B.arena, types.int_type)) },
        .filename => .{ .type = try B.func(types.node_type, try B.declared.maybe(B.arena, types.string_type)) },
        .parent,
        .ancestors,
        .children,
        .named_children,
        .descendants,
        .named_descendants,
        => .{ .type = try B.listFunction(types.node_type, types.node_type) },
        .children_of_kind, .descendants_of_kind => .{ .type = try B.func(
            types.kind_type,
            try B.listFunction(types.node_type, types.node_type),
        ) },
        .is_kind => .{ .type = try B.func(types.kind_type, try B.func(types.node_type, try B.boolType())) },
        inline else => |p| {
            const c = comptime p.compared() orelse @compileError("no scheme for " ++ @tagName(p));
            const operand = c.operands.named();
            const result = switch (c.comparison) {
                .compare => try B.declared.orderingType(B.arena),
                else => try B.boolType(),
            };
            return .{ .type = try B.func(operand, try B.func(operand, result)) };
        },
    };
}

/// Type construction against one arena and registry.
const Builder = struct {
    arena: Allocator,
    declared: *const datatypes.Registry,

    fn func(self: Builder, from: types.Type, to: types.Type) !types.Type {
        return try types.func(self.arena, from, to);
    }

    /// `input -> [output]`.
    fn listFunction(self: Builder, input: types.Type, output: types.Type) !types.Type {
        return try types.func(self.arena, input, try datatypes.list(self.arena, output));
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
) Allocator.Error!types.Scheme {
    const B = Builder{ .arena = arena, .declared = declared };

    return switch (operator) {
        .match, .not_match => .{ .type = try B.func(
            types.string_type,
            try B.func(types.regex_type, try B.boolType()),
        ) },
        .add, .subtract, .multiply => .{ .type = try B.func(
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
        .field => .{ .type = try B.listFunction(types.node_type, types.node_type) },
        .operator => |operator| try operatorScheme(arena, declared, operator),
        .record => |labels| try recordScheme(arena, labels),
        .select => |label| try selectScheme(arena, label),
        // Elaboration and lowering build these, after checking.
        .fold, .map, .record_size, .record_label, .record_field, .record_insert => unreachable,
    };
}

/// `record[l_1,...,l_n] : t_1 -> ... -> t_n -> {l_1: t_1, ..., l_n: t_n}`.
///
/// Built per symbol, since its shape depends on the labels. Quantifies one
/// variable per field.
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
    var result = try datatypes.record(arena, .{ .fields = fields });
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        result = try types.func(arena, types.variable_type(@intCast(i)), result);
    }

    return .{ .variables = types.typeKinds(labels.len), .type = result };
}

/// `select[l] : forall t r. {l: t | r} -> t`.
fn selectScheme(arena: Allocator, label: []const u8) Allocator.Error!types.Scheme {
    const field = types.variable_type(0);
    const fields = try arena.alloc(types.Type.Field, 1);
    fields[0] = .{ .label = label, .type = try types.store(arena, field) };
    const subject = try datatypes.record(arena, .{
        .fields = fields,
        .tail = try types.store(arena, types.variable_type(1)),
    });
    return .{ .variables = &.{ .type, .row }, .type = try types.func(arena, subject, field) };
}

/// Declares the built-in types, then interns the primitives with their
/// schemes, in no module. Called once on a fresh environment, before any body
/// is resolved.
pub fn populate(target: *core.env.Env) !void {
    try target.datatypes.reserveBuiltins(&target.interner);

    const B = Builder{ .arena = target.allocator(), .declared = &target.datatypes };
    for (std.enums.values(PrimOp)) |primop| {
        const scheme = try schemeOf(B, primop);
        const id = try target.interner.internOrGet(primop.spelling(), .{ .primop = primop });
        try target.setScheme(id, scheme);
        target.primitives.set(primop, id);
    }
    for (std.enums.values(Pseudo)) |pseudo| {
        _ = try target.interner.internOrGet(pseudo.spelling(), .{ .pseudo = pseudo });
    }
}

/// The synthesized symbol spelled `spelling`, interned as `what` with its
/// scheme on first use.
///
/// Preconditions:
/// - What `what` points to outlives `target`.
fn synthesizedSymbol(target: *core.env.Env, spelling: []const u8, what: core.Synthesized) SchemeError!core.SymbolId {
    const id = try target.interner.internOrGet(spelling, .{ .synthesized = what });
    if (target.schemeOf(id) == null) {
        try target.setScheme(id, try synthesizedScheme(target.allocator(), &target.datatypes, what));
    }
    return id;
}

/// `op[s]`, the scalar operator `scalar`, with its scheme.
pub fn operatorSymbol(target: *core.env.Env, scalar: core.Scalar) Allocator.Error!core.SymbolId {
    return try bounded(target, "op[{s}]", .{scalar.spelling()}, .{ .operator = scalar });
}

/// `record[l_1,...,l_n]`, building a record with `labels`, in normalized
/// order, with its scheme.
pub fn recordSymbol(target: *core.env.Env, labels: []const []const u8) SchemeError!core.SymbolId {
    const joined = try std.mem.join(target.gpa, ",", labels);
    defer target.gpa.free(joined);
    return try symbolOf(target, "record[{s}]", .{joined}, .{ .record = labels });
}

/// `record[]`, the record with no fields, with its scheme.
pub fn emptyRecordSymbol(target: *core.env.Env) Allocator.Error!core.SymbolId {
    return try bounded(target, "record[]", .{}, .{ .record = &.{} });
}

/// `field[name]`, the children in the grammar field `name`, numbered `id`,
/// with its scheme.
pub fn fieldSymbol(target: *core.env.Env, name: []const u8, id: u16) Allocator.Error!core.SymbolId {
    return try bounded(target, "field[{s}]", .{name}, .{ .field = .{ .name = name, .id = id } });
}

/// `select[label]`, reading the record field `label`, with its scheme.
pub fn selectSymbol(target: *core.env.Env, label: []const u8) Allocator.Error!core.SymbolId {
    return try bounded(target, "select[{s}]", .{label}, .{ .select = label });
}

/// `symbolOf` for a symbol whose scheme has at most one field.
fn bounded(target: *core.env.Env, comptime format: []const u8, args: anytype, what: core.Synthesized) Allocator.Error!core.SymbolId {
    return symbolOf(target, format, args, what) catch |err| switch (err) {
        error.TooManyRecordFields => unreachable,
        error.OutOfMemory => |e| return e,
    };
}

/// The symbol spelled by `format`, interned as a copy of `what` with its
/// scheme on first use.
fn symbolOf(
    target: *core.env.Env,
    // IMPROVE: normalize differently in a non-stupid way
    comptime format: []const u8,
    args: anytype,
    what: core.Synthesized,
) SchemeError!core.SymbolId {
    const spelling = try std.fmt.allocPrint(target.gpa, format, args);
    defer target.gpa.free(spelling);
    if (target.interner.lookup(null, spelling)) |id| return id;
    return try synthesizedSymbol(target, spelling, try what.dupe(target.allocator()));
}

/// The symbol of `operation`, which elaboration or lowering builds after
/// checking. It has no scheme.
pub fn elaboratedSymbol(target: *core.env.Env, comptime operation: std.meta.Tag(core.Synthesized)) Allocator.Error!core.SymbolId {
    return try target.interner.internOrGet(elaboratedSpelling(operation), .{ .synthesized = @unionInit(core.Synthesized, @tagName(operation), {}) });
}

pub fn elaboratedSpelling(operation: std.meta.Tag(core.Synthesized)) []const u8 {
    return switch (operation) {
        .fold => "fold[All]",
        .map => "map[All]",
        else => @tagName(operation),
    };
}
