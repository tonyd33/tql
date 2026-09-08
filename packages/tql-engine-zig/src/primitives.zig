const std = @import("std");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const Scheme = types.Scheme;
const SymbolId = symbols.SymbolId;

pub const Lowering = enum {
    identity,
    pure,
    compose,
    @"union",
    flat_map,
    branch,
    not,
    @"and",
    @"or",
    empty,
    probe,
    collect,
    text,
    kind,
    range,
    length,
    unnest,
    toint,
    filename,
    parent,
    ancestors,
    children,
    descendants,
    is_kind,
    field,
    operator,
    record_filter,
};

const primitive_meta = [_]struct {
    name: []const u8,
    scheme: Scheme,
    lowering: Lowering,
}{
    .{
        .name = "identity",
        .scheme = .{ .quantified = 1, .type = types.filter_type(
            types.variable_type(0),
            types.variable_type(0),
        ) },
        .lowering = .identity,
    },
    .{
        .name = "pure",
        .scheme = .{ .quantified = 2, .type = types.func_type(
            types.variable_type(0),
            types.filter_type(types.variable_type(1), types.variable_type(0)),
        ) },
        .lowering = .pure,
    },
    .{
        .name = "compose",
        .scheme = .{
            .quantified = 3,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.variable_type(1)),
                types.func_type(
                    types.filter_type(types.variable_type(1), types.variable_type(2)),
                    types.filter_type(types.variable_type(0), types.variable_type(2)),
                ),
            ),
        },
        .lowering = .compose,
    },
    .{
        .name = "union",
        .scheme = .{
            .quantified = 2,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.variable_type(1)),
                types.func_type(
                    types.filter_type(types.variable_type(0), types.variable_type(1)),
                    types.filter_type(types.variable_type(0), types.variable_type(1)),
                ),
            ),
        },
        .lowering = .@"union",
    },
    .{
        .name = "flat_map",
        .scheme = .{
            .quantified = 2,
            .type = types.func_type(
                types.list_type(types.variable_type(0)),
                types.func_type(
                    types.func_type(types.variable_type(0), types.list_type(types.variable_type(1))),
                    types.list_type(types.variable_type(1)),
                ),
            ),
        },
        .lowering = .flat_map,
    },
    .{
        .name = "branch",
        .scheme = .{
            .quantified = 2,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.bool_type),
                types.func_type(
                    types.filter_type(types.variable_type(0), types.variable_type(1)),
                    types.func_type(
                        types.filter_type(types.variable_type(0), types.variable_type(1)),
                        types.filter_type(types.variable_type(0), types.variable_type(1)),
                    ),
                ),
            ),
        },
        .lowering = .branch,
    },
    .{
        .name = "not",
        .scheme = .{
            .quantified = 1,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.bool_type),
                types.filter_type(types.variable_type(0), types.bool_type),
            ),
        },
        .lowering = .not,
    },
    .{
        .name = "and",
        .scheme = .{
            .quantified = 1,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.bool_type),
                types.func_type(
                    types.filter_type(types.variable_type(0), types.bool_type),
                    types.filter_type(types.variable_type(0), types.bool_type),
                ),
            ),
        },
        .lowering = .@"and",
    },
    .{
        .name = "or",
        .scheme = .{
            .quantified = 1,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.bool_type),
                types.func_type(
                    types.filter_type(types.variable_type(0), types.bool_type),
                    types.filter_type(types.variable_type(0), types.bool_type),
                ),
            ),
        },
        .lowering = .@"or",
    },
    .{
        .name = "empty",
        .scheme = .{ .quantified = 2, .type = types.filter_type(
            types.variable_type(0),
            types.variable_type(1),
        ) },
        .lowering = .empty,
    },
    .{
        .name = "probe",
        .scheme = .{
            .quantified = 2,
            .type = types.func_type(
                types.filter_type(
                    types.variable_type(0),
                    types.variable_type(1),
                ),
                types.filter_type(types.variable_type(0), types.bool_type),
            ),
        },
        .lowering = .probe,
    },
    .{
        .name = "collect",
        .scheme = .{
            .quantified = 2,
            .type = types.func_type(
                types.filter_type(types.variable_type(0), types.variable_type(1)),
                types.filter_type(types.variable_type(0), types.list_type(types.variable_type(1))),
            ),
        },
        .lowering = .collect,
    },
    .{
        .name = "text",
        .scheme = .{ .type = types.filter_type(types.node_type, types.string_type) },
        .lowering = .text,
    },
    .{
        .name = "kind",
        .scheme = .{ .type = types.filter_type(types.node_type, types.string_type) },
        .lowering = .kind,
    },
    .{
        .name = "range",
        .scheme = .{ .type = types.filter_type(types.node_type, types.range_type) },
        .lowering = .range,
    },
    .{
        .name = "length",
        .scheme = .{
            .quantified = 1,
            .constraints = &.{.{ .class = .Sized, .type = types.variable_type(0) }},
            .type = types.filter_type(types.variable_type(0), types.int_type),
        },
        .lowering = .length,
    },
    .{
        .name = "unnest",
        .scheme = .{
            .quantified = 1,
            .type = types.filter_type(types.list_type(types.variable_type(0)), types.variable_type(0)),
        },
        .lowering = .unnest,
    },
    .{
        .name = "toint",
        .scheme = .{ .type = types.filter_type(types.string_type, types.int_type) },
        .lowering = .toint,
    },
    .{
        .name = "filename",
        .scheme = .{ .type = types.filter_type(types.node_type, types.string_type) },
        .lowering = .filename,
    },
    .{
        .name = "parent",
        .scheme = .{ .type = types.filter_type(types.node_type, types.node_type) },
        .lowering = .parent,
    },
    .{
        .name = "ancestors",
        .scheme = .{ .type = types.filter_type(types.node_type, types.node_type) },
        .lowering = .ancestors,
    },
    .{
        .name = "children",
        .scheme = .{ .type = types.filter_type(types.node_type, types.node_type) },
        .lowering = .children,
    },
    .{
        .name = "descendants",
        .scheme = .{ .type = types.filter_type(types.node_type, types.node_type) },
        .lowering = .descendants,
    },
};

const operator_meta = [_]struct {
    spelling: []const u8,
    scheme: Scheme,
}{
    .{ .spelling = "=", .scheme = comparison(.Eq) },
    .{ .spelling = "!=", .scheme = comparison(.Eq) },
    .{ .spelling = "<", .scheme = comparison(.Ord) },
    .{ .spelling = "<=", .scheme = comparison(.Ord) },
    .{ .spelling = ">", .scheme = comparison(.Ord) },
    .{ .spelling = ">=", .scheme = comparison(.Ord) },
    .{ .spelling = "~", .scheme = matching() },
    .{ .spelling = "!~", .scheme = matching() },
    .{ .spelling = "+", .scheme = arithmetic() },
    .{ .spelling = "-", .scheme = arithmetic() },
    .{ .spelling = "*", .scheme = arithmetic() },
    .{ .spelling = "/", .scheme = arithmetic() },
    .{ .spelling = "%", .scheme = arithmetic() },
};

fn comparison(comptime class: types.TypeClassConstraint.Class) Scheme {
    return .{
        .quantified = 1,
        .constraints = &.{.{ .class = class, .type = types.variable_type(0) }},
        .type = types.func_type(types.variable_type(0), types.func_type(types.variable_type(0), types.bool_type)),
    };
}

fn matching() Scheme {
    return .{ .type = types.func_type(types.string_type, types.func_type(types.regex_type, types.bool_type)) };
}

fn arithmetic() Scheme {
    return .{ .type = types.func_type(types.int_type, types.func_type(types.int_type, types.int_type)) };
}

/// What each primitive is, keyed by the id it was interned as.
pub const Table = struct {
    schemes: symbols.SymbolTable(Scheme),
    lowerings: symbols.SymbolTable(Lowering),

    pub fn deinit(self: *Table) void {
        self.schemes.deinit();
        self.lowerings.deinit();
    }

    pub fn scheme(self: *const Table, id: SymbolId) ?Scheme {
        return self.schemes.get(id);
    }

    pub fn lowering(self: *const Table, id: SymbolId) ?Lowering {
        return self.lowerings.get(id);
    }

    pub fn contains(self: *const Table, id: SymbolId) bool {
        return self.lowerings.get(id) != null;
    }
};

/// An interner with the primitives already interned, paired with the table
/// saying what they are. The two are created and destroyed together because the
/// ids in one only mean anything against the other.
pub const Interned = struct {
    interner: symbols.Interner,
    table: Table,

    /// Interns the primitives. Called once, before any body is resolved, so a
    /// declaration colliding with a primitive's name fails on intern.
    pub fn init(allocator: Allocator) !Interned {
        var interner = try symbols.Interner.init(allocator);
        errdefer interner.deinit();

        var table: Table = .{
            .schemes = symbols.SymbolTable(Scheme).init(allocator),
            .lowerings = symbols.SymbolTable(Lowering).init(allocator),
        };
        errdefer table.deinit();

        for (primitive_meta) |row| {
            const id = try interner.intern(row.name);
            try table.schemes.put(id, row.scheme);
            try table.lowerings.put(id, row.lowering);
        }
        return .{ .interner = interner, .table = table };
    }

    pub fn deinit(self: *Interned) void {
        self.table.deinit();
        self.interner.deinit();
    }
};

/// The scheme for a scalar operator spelling. A property of the spelling, not
/// of an interned id, so it is a lookup rather than a table entry.
pub fn operatorScheme(spelling_text: []const u8) ?Scheme {
    for (operator_meta) |row| {
        if (std.mem.eql(u8, row.spelling, spelling_text)) return row.scheme;
    }
    return null;
}

test "primitives are the documented set" {
    // Held by hand against the language definition. A row added to one side and
    // not the other fails here rather than drifting silently.
    const expected = [_][]const u8{
        "identity",  "pure",     "compose",     "union",
        "flat_map",  "branch",   "not",         "and",
        "or",        "empty",    "probe",       "collect",
        "text",      "kind",     "range",       "length",
        "unnest",    "toint",    "filename",    "parent",
        "ancestors", "children", "descendants",
    };
    try std.testing.expectEqual(expected.len, primitive_meta.len);
    for (expected, primitive_meta) |name, row| {
        try std.testing.expectEqualStrings(name, row.name);
    }
}

test "every primitive is interned, and its scheme and lowering are recorded" {
    var interned = try Interned.init(std.testing.allocator);
    defer interned.deinit();

    try std.testing.expectEqual(primitive_meta.len, interned.interner.count());

    const compose = interned.interner.lookup("compose") orelse return error.Missing;
    try std.testing.expectEqualStrings("compose", interned.interner.spelling(compose));
    try std.testing.expect(interned.table.contains(compose));
    try std.testing.expectEqual(Lowering.compose, interned.table.lowering(compose).?);
    try std.testing.expect(interned.table.scheme(compose) != null);
}

test "a declaration colliding with a primitive's name is rejected" {
    var interned = try Interned.init(std.testing.allocator);
    defer interned.deinit();

    try std.testing.expectError(error.Collision, interned.interner.intern("children"));
}

test "operator schemes take scalars, not filters" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();

    try operatorScheme("=").?.format(&buf.writer);
    try std.testing.expectEqualStrings("Eq a => a -> a -> bool", buf.written());

    buf.clearRetainingCapacity();
    try operatorScheme("+").?.format(&buf.writer);
    try std.testing.expectEqualStrings("int -> int -> int", buf.written());
}
