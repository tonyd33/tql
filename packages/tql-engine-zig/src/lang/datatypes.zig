//! Declared algebraic data types and their constructors.

const std = @import("std");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const TypeId = enum(u32) { _ };

/// Which classes a declared type admits, and whether its parameters must
/// admit them too.
pub const Entailment = enum {
    /// Never holds.
    never,
    /// Holds unconditionally.
    always,
    /// Holds when every field type holds.
    fields,
};

pub const ClassRow = struct {
    Eq: Entailment = .never,
    Ord: Entailment = .never,
    Sized: Entailment = .never,
    Serial: Entailment = .never,

    pub fn forClass(self: ClassRow, class: types.TypeClassConstraint.Class) Entailment {
        return switch (class) {
            .Eq => self.Eq,
            .Ord => self.Ord,
            .Sized => self.Sized,
            .Serial => self.Serial,
        };
    }
};

pub const Constructor = struct {
    symbol: symbols.SymbolId,
    /// Dispatch index within the datatype: `Nil` is 0, `Cons` is 1.
    tag: u32,
    /// Field types, which may name the datatype's parameters as
    /// `types.Type.variable`.
    fields: []const types.Type,
};

pub const Datatype = struct {
    name: []const u8,
    /// Count of bound type parameters, numbered from zero.
    parameters: u8,
    constructors: []const Constructor,
    classes: ClassRow,
};

/// The declared types of one linked program.
pub const Registry = struct {
    allocator: Allocator,
    datatypes: std.ArrayList(Datatype) = .empty,
    by_name: std.StringHashMapUnmanaged(TypeId) = .empty,
    /// Which datatype a constructor belongs to, for `case` and for scheme
    /// construction.
    constructor_owner: symbols.SymbolTable(TypeId),

    pub fn init(allocator: Allocator) Registry {
        return .{
            .allocator = allocator,
            .constructor_owner = symbols.SymbolTable(TypeId).init(allocator),
        };
    }

    /// Declares `List` and `Bool`. The primitive schemes mention both, so they
    /// must exist before `prelude.tql` is parsed.
    pub fn declareStructural(
        self: *Registry,
        interner: *symbols.Interner,
        arena: Allocator,
    ) !void {
        const element = types.variable_type(0);
        const self_ref = try types.constructed(
            arena,
            @enumFromInt(self.datatypes.items.len),
            types.list_spelling,
            &.{element},
        );

        const cons_fields = try arena.dupe(types.Type, &.{ element, self_ref });
        const list_constructors = try arena.dupe(Constructor, &.{
            .{ .symbol = try interner.intern("Nil"), .tag = 0, .fields = &.{} },
            .{ .symbol = try interner.intern("Cons"), .tag = 1, .fields = cons_fields },
        });
        _ = try self.declare(types.list_spelling, 1, list_constructors, .{
            .Eq = .fields,
            .Sized = .always,
            .Serial = .fields,
        });

        const bool_constructors = try arena.dupe(Constructor, &.{
            .{ .symbol = try interner.intern("False"), .tag = 0, .fields = &.{} },
            .{ .symbol = try interner.intern("True"), .tag = 1, .fields = &.{} },
        });
        _ = try self.declare(types.bool_spelling, 0, bool_constructors, .{
            .Eq = .always,
            .Serial = .always,
        });
    }

    pub fn listId(self: *const Registry) TypeId {
        return self.lookup(types.list_spelling).?;
    }

    pub fn boolId(self: *const Registry) TypeId {
        return self.lookup(types.bool_spelling).?;
    }

    /// `[t]`, for a caller that has the registry.
    pub fn list(self: *const Registry, arena: Allocator, element: types.Type) !types.Type {
        return try types.constructed(arena, self.listId(), types.list_spelling, &.{element});
    }

    /// `Bool`.
    pub fn boolType(self: *const Registry, arena: Allocator) !types.Type {
        return try types.constructed(arena, self.boolId(), types.bool_spelling, &.{});
    }

    /// `Filter a b` = `a -> [b]`.
    pub fn filter(
        self: *const Registry,
        arena: Allocator,
        input: types.Type,
        output: types.Type,
    ) !types.Type {
        return try types.func(arena, input, try self.list(arena, output));
    }

    pub fn deinit(self: *Registry) void {
        self.datatypes.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
        self.constructor_owner.deinit();
    }

    /// `name` and the constructor slice must outlive the registry; both are
    /// expected to live in the program arena.
    pub fn declare(
        self: *Registry,
        name: []const u8,
        parameters: u8,
        constructors: []const Constructor,
        classes: ClassRow,
    ) Allocator.Error!TypeId {
        const id: TypeId = @enumFromInt(self.datatypes.items.len);
        try self.datatypes.append(self.allocator, .{
            .name = name,
            .parameters = parameters,
            .constructors = constructors,
            .classes = classes,
        });
        try self.by_name.put(self.allocator, name, id);
        for (constructors) |c| try self.constructor_owner.put(c.symbol, id);
        return id;
    }

    /// Fills in a type declared with no constructors yet. A recursive type's
    /// fields need the name in scope before they resolve.
    pub fn setConstructors(
        self: *Registry,
        id: TypeId,
        constructors: []const Constructor,
    ) Allocator.Error!void {
        self.datatypes.items[@intFromEnum(id)].constructors = constructors;
        for (constructors) |c| try self.constructor_owner.put(c.symbol, id);
    }

    pub fn get(self: *const Registry, id: TypeId) *const Datatype {
        return &self.datatypes.items[@intFromEnum(id)];
    }

    pub fn lookup(self: *const Registry, name: []const u8) ?TypeId {
        return self.by_name.get(name);
    }

    pub fn ownerOf(self: *const Registry, constructor: symbols.SymbolId) ?TypeId {
        return self.constructor_owner.get(constructor);
    }

    pub fn constructorOf(
        self: *const Registry,
        constructor: symbols.SymbolId,
    ) ?*const Constructor {
        const owner = self.ownerOf(constructor) orelse return null;
        for (self.get(owner).constructors) |*c| {
            if (c.symbol == constructor) return c;
        }
        return null;
    }
};

test "a declared type is reachable by name, id, and constructor" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const nil: symbols.SymbolId = @enumFromInt(0);
    const cons: symbols.SymbolId = @enumFromInt(1);
    const constructors = [_]Constructor{
        .{ .symbol = nil, .tag = 0, .fields = &.{} },
        .{ .symbol = cons, .tag = 1, .fields = &.{} },
    };

    const id = try registry.declare("List", 1, &constructors, .{
        .Eq = .fields,
        .Sized = .always,
        .Serial = .fields,
    });

    try std.testing.expectEqual(id, registry.lookup("List").?);
    try std.testing.expectEqual(1, registry.get(id).parameters);
    try std.testing.expectEqual(id, registry.ownerOf(cons).?);
    try std.testing.expectEqual(1, registry.constructorOf(cons).?.tag);
    try std.testing.expectEqual(null, registry.ownerOf(@enumFromInt(9)));
}

test "a list is Sized whatever its elements are, but Ord never" {
    const row: ClassRow = .{ .Eq = .fields, .Sized = .always, .Serial = .fields };
    try std.testing.expectEqual(Entailment.always, row.forClass(.Sized));
    try std.testing.expectEqual(Entailment.fields, row.forClass(.Eq));
    try std.testing.expectEqual(Entailment.never, row.forClass(.Ord));
}
