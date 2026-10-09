//! Declared algebraic data types and their constructors.

const std = @import("std");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const TypeId = symbols.TypeId;

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
    /// The module that declares it.
    module: symbols.ModuleId,
    /// Count of bound type parameters, numbered from zero.
    parameters: u8,
    constructors: []const Constructor,
};

/// `type Named r = {name: String | r};`
pub const Alias = struct {
    name: []const u8,
    parameters: []const Parameter,
    /// Names parameter `i` as `types.Type.variable` `i`.
    body: types.Type,

    pub const Parameter = struct {
        name: []const u8,
        sort: Sort,
    };

    /// What a type variable stands for: a type, or the fields after `|` in
    /// an open record.
    pub const Sort = enum { type, row };

    /// The alias at `arguments`, expanded. Takes ownership of `arguments`.
    pub fn apply(self: *const Alias, allocator: Allocator, arguments: []const types.Type) Allocator.Error!types.Type {
        return try types.aliased(allocator, self.name, arguments, try types.substitute(allocator, self.body, arguments));
    }
};

/// The declared types of one linked program.
pub const Registry = struct {
    allocator: Allocator,
    datatypes: std.ArrayList(Datatype) = .empty,
    by_name: symbols.QualifiedName.Map(TypeId) = .empty,
    aliases: symbols.QualifiedName.Map(Alias) = .empty,
    primitives: symbols.QualifiedName.Map(types.Primitive) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// What the machine expects of a type it builds values of directly.
    ///
    /// The prelude declares `List`, `Bool` and `Ordering`; these rows reserve
    /// their ids so a primitive scheme can name any of them before the prelude
    /// is parsed.
    pub const Structural = struct {
        name: []const u8,
        parameters: u8,
        /// Constructor spellings in tag order.
        constructors: []const []const u8,

        pub const list: Structural = .{
            .name = types.list_spelling,
            .parameters = 1,
            .constructors = &.{ "Nil", "Cons" },
        };

        pub const boolean: Structural = .{
            .name = types.bool_spelling,
            .parameters = 0,
            .constructors = &.{ "False", "True" },
        };

        pub const ordering: Structural = .{
            .name = types.ordering_spelling,
            .parameters = 0,
            .constructors = &.{ "LT", "EQ", "GT" },
        };

        pub const all: []const Structural = &.{ Structural.list, Structural.boolean, Structural.ordering };
    };

    /// Declares the prelude's built-in types: the primitives, the aliases
    /// `Range` and `Point`, and `List`, `Bool` and `Ordering` with no
    /// constructors yet. The primitive schemes mention them, so their ids must
    /// exist before `prelude.tql` is parsed; the prelude's own declarations
    /// fill the constructors in.
    pub fn reserveBuiltins(self: *Registry, interner: *symbols.Interner) !void {
        for (std.enums.values(types.Primitive)) |p| {
            try self.primitives.put(self.allocator, .{ .module = .prelude, .name = p.spelling() }, p);
        }
        for ([_]types.Type{ types.range_type, types.point_type }) |t| {
            try self.defineAlias(.prelude, .{ .name = t.alias.spelling, .parameters = &.{}, .body = t.alias.expansion });
        }
        for (Structural.all) |s| {
            _ = try self.declare(interner, .prelude, s.name, s.parameters, &.{});
        }
    }

    /// The reservation `name` names, when it names one.
    pub fn structuralNamed(name: []const u8) ?Structural {
        for (Structural.all) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn listId(self: *const Registry) TypeId {
        return self.lookup(.prelude, types.list_spelling).?;
    }

    pub fn boolId(self: *const Registry) TypeId {
        return self.lookup(.prelude, types.bool_spelling).?;
    }

    /// The constructor `b` denotes. `False` is tag 0 and `True` is tag 1,
    /// fixed by `Structural.boolean`; a caller building a boolean value must
    /// not assume that order itself.
    pub fn boolConstructor(self: *const Registry, b: bool) Constructor {
        return self.get(self.boolId()).constructors[if (b) 1 else 0];
    }

    pub fn orderingId(self: *const Registry) TypeId {
        return self.lookup(.prelude, types.ordering_spelling).?;
    }

    /// The constructor `order` denotes: `LT`, `EQ` or `GT`, tags 0 to 2 of
    /// `Ordering`.
    pub fn orderingConstructor(self: *const Registry, order: std.math.Order) Constructor {
        return self.get(self.orderingId()).constructors[
            switch (order) {
                .lt => 0,
                .eq => 1,
                .gt => 2,
            }
        ];
    }

    /// `Nil`, tag 0 of `List`.
    pub fn nilConstructor(self: *const Registry) Constructor {
        return self.get(self.listId()).constructors[0];
    }

    /// `Cons`, tag 1 of `List`, taking a head and a tail.
    pub fn consConstructor(self: *const Registry) Constructor {
        return self.get(self.listId()).constructors[1];
    }

    /// The scheme of `constructor`, of type `id`: its fields curried onto the
    /// type at its own parameters.
    pub fn constructorScheme(
        self: *const Registry,
        arena: Allocator,
        id: TypeId,
        constructor: Constructor,
    ) Allocator.Error!types.Scheme {
        const result = try self.applied(arena, id);
        return .{ .quantified = self.get(id).parameters, .type = try types.arrows(arena, constructor.fields, result) };
    }

    /// `id` applied to its own parameters, in order.
    pub fn applied(self: *const Registry, arena: Allocator, id: TypeId) Allocator.Error!types.Type {
        const declared = self.get(id);
        const arguments = try arena.alloc(types.Type, declared.parameters);
        for (arguments, 0..) |*argument, i| argument.* = types.variable_type(@intCast(i));
        return try types.constructed(arena, id, declared.name, arguments);
    }

    /// `[t]`, for a caller that has the registry.
    pub fn list(self: *const Registry, arena: Allocator, element: types.Type) !types.Type {
        return try types.constructed(arena, self.listId(), types.list_spelling, &.{element});
    }

    /// `Bool`.
    pub fn boolType(self: *const Registry, arena: Allocator) !types.Type {
        return try types.constructed(arena, self.boolId(), types.bool_spelling, &.{});
    }

    /// `Ordering`.
    pub fn orderingType(self: *const Registry, arena: Allocator) !types.Type {
        return try types.constructed(arena, self.orderingId(), types.ordering_spelling, &.{});
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

    /// `name` and the constructor slice must outlive the registry; both are
    /// expected to live in the program arena. Each constructor's symbol is
    /// pointed back at the datatype declaring it.
    pub fn declare(
        self: *Registry,
        interner: *symbols.Interner,
        module: symbols.ModuleId,
        name: []const u8,
        parameters: u8,
        constructors: []const Constructor,
    ) Allocator.Error!TypeId {
        const id: TypeId = @enumFromInt(self.datatypes.items.len);
        try self.datatypes.append(self.allocator, .{
            .name = name,
            .module = module,
            .parameters = parameters,
            .constructors = constructors,
        });
        try self.by_name.put(self.allocator, .{ .module = module, .name = name }, id);
        own(interner, id, constructors);
        return id;
    }

    /// Fills in a type declared with no constructors yet. A recursive type's
    /// fields need the name in scope before they resolve.
    pub fn setConstructors(
        self: *Registry,
        interner: *symbols.Interner,
        id: TypeId,
        constructors: []const Constructor,
    ) void {
        self.datatypes.items[@intFromEnum(id)].constructors = constructors;
        own(interner, id, constructors);
    }

    fn own(interner: *symbols.Interner, id: TypeId, constructors: []const Constructor) void {
        for (constructors) |c| {
            interner.setDetails(c.symbol, .{ .constructor = .{ .owner = id, .tag = c.tag } });
        }
    }

    pub fn get(self: *const Registry, id: TypeId) *const Datatype {
        return &self.datatypes.items[@intFromEnum(id)];
    }

    /// The datatype `module` declares as `name`.
    pub fn lookup(self: *const Registry, module: symbols.ModuleId, name: []const u8) ?TypeId {
        return self.by_name.get(.{ .module = module, .name = name });
    }

    /// `alias` and everything it points to must outlive the registry.
    pub fn defineAlias(self: *Registry, module: symbols.ModuleId, alias: Alias) Allocator.Error!void {
        try self.aliases.put(self.allocator, .{ .module = module, .name = alias.name }, alias);
    }

    /// The primitive type `module` declares as `name`.
    pub fn primitiveNamed(self: *const Registry, module: symbols.ModuleId, name: []const u8) ?types.Primitive {
        return self.primitives.get(.{ .module = module, .name = name });
    }

    /// The alias `module` declares as `name`.
    pub fn aliasNamed(self: *const Registry, module: symbols.ModuleId, name: []const u8) ?*const Alias {
        return self.aliases.getPtr(.{ .module = module, .name = name });
    }

    pub fn constructorOf(
        self: *const Registry,
        interner: *const symbols.Interner,
        constructor: symbols.SymbolId,
    ) ?*const Constructor {
        return switch (interner.details(constructor)) {
            .constructor => |c| &self.get(c.owner).constructors[c.tag],
            else => null,
        };
    }
};

/// The datatype declaring `constructor`, when the symbol is one.
pub fn ownerOf(interner: *const symbols.Interner, constructor: symbols.SymbolId) ?TypeId {
    return switch (interner.details(constructor)) {
        .constructor => |c| c.owner,
        else => null,
    };
}

const test_support = @import("test_support.zig");

test "a declared type is reachable by name, id, and constructor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    var interner = symbols.Interner.init(arena.allocator());

    const nil = try interner.intern(.prelude, "Nil", .vanilla);
    const cons = try interner.intern(.prelude, "Cons", .vanilla);
    const other = try interner.intern(.prelude, "other", .vanilla);
    const constructors = [_]Constructor{
        .{ .symbol = nil, .tag = 0, .fields = &.{} },
        .{ .symbol = cons, .tag = 1, .fields = &.{} },
    };

    const id = try registry.declare(&interner, .prelude, "List", 1, &constructors);

    try std.testing.expectEqual(id, registry.lookup(.prelude, "List").?);
    try std.testing.expectEqual(1, registry.get(id).parameters);
    try std.testing.expectEqual(id, ownerOf(&interner, cons).?);
    try std.testing.expectEqual(1, registry.constructorOf(&interner, cons).?.tag);
    try std.testing.expectEqual(null, ownerOf(&interner, other));
}

test "the structural accessors follow the declared tag order" {
    var e = try test_support.env(std.testing.allocator);
    defer e.deinit();
    const registry = &e.datatypes;
    const interner = &e.interner;

    const f = registry.boolConstructor(false);
    const t = registry.boolConstructor(true);
    try std.testing.expectEqualStrings("False", interner.spelling(f.symbol));
    try std.testing.expectEqualStrings("True", interner.spelling(t.symbol));
    try std.testing.expectEqual(0, f.tag);
    try std.testing.expectEqual(1, t.tag);

    const n = registry.nilConstructor();
    const c = registry.consConstructor();
    try std.testing.expectEqualStrings("Nil", interner.spelling(n.symbol));
    try std.testing.expectEqualStrings("Cons", interner.spelling(c.symbol));
    try std.testing.expectEqual(0, n.tag);
    try std.testing.expectEqual(1, c.tag);

    const lt = registry.orderingConstructor(.lt);
    const gt = registry.orderingConstructor(.gt);
    try std.testing.expectEqualStrings("LT", interner.spelling(lt.symbol));
    try std.testing.expectEqualStrings("GT", interner.spelling(gt.symbol));
    try std.testing.expectEqual(0, lt.tag);
    try std.testing.expectEqual(2, gt.tag);
}
