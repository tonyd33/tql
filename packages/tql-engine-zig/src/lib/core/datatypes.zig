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
    /// The kind of each bound type parameter, numbered from zero.
    parameters: []const types.Kind,
    constructors: []const Constructor,
    /// Set from `reserveBuiltins` until `Prim`'s declaration claims it.
    reserved: bool = false,
};

/// `type Named r = {name: String | r};`
pub const Alias = struct {
    name: []const u8,
    parameters: []const Parameter,
    /// Names parameter `i` as `types.Type.variable` `i`.
    body: types.Type,
    /// The kind of `body`.
    kind: types.Kind,

    pub const Parameter = struct {
        name: []const u8,
        kind: types.Kind,
    };

    /// The alias at `arguments`, expanded. Arguments past its parameters
    /// apply the expansion. Takes ownership of `arguments`.
    ///
    /// Preconditions:
    /// - `arguments` has at least one per parameter.
    pub fn apply(self: *const Alias, allocator: Allocator, arguments: []const types.Type) Allocator.Error!types.Type {
        var expansion = try types.substitute(allocator, self.body, arguments[0..self.parameters.len]);
        for (arguments[self.parameters.len..]) |argument| expansion = try types.apply(allocator, expansion, argument);
        return try types.aliased(allocator, self.name, arguments, expansion);
    }
};

/// The declared types of one linked program.
pub const Registry = struct {
    allocator: Allocator,
    datatypes: std.ArrayList(Datatype) = .empty,
    by_name: symbols.QualifiedName.Map(TypeId) = .empty,
    /// A pointer to an alias stays valid as more are defined.
    aliases: symbols.QualifiedName.Map(*const Alias) = .empty,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// A copy allocated from `allocator`, sharing the datatypes' contents.
    pub fn clone(self: *const Registry, allocator: Allocator) Allocator.Error!Registry {
        return .{
            .allocator = allocator,
            .datatypes = try self.datatypes.clone(allocator),
            .by_name = try self.by_name.clone(allocator),
            .aliases = try self.aliases.clone(allocator),
        };
    }

    /// What the machine expects of a type it builds values of directly.
    ///
    /// `Prim` declares the primitives, `List`, `Bool` and `Ordering`; these
    /// rows reserve their ids so a primitive scheme can name any of them
    /// before `Prim` is parsed.
    pub const Structural = struct {
        name: []const u8,
        parameters: []const types.Kind,
        /// Constructor spellings in tag order.
        constructors: []const []const u8 = &.{},
        /// Set for `data Int = %Int;`, which has no constructors.
        representation: ?types.Primitive = null,

        fn primitive(comptime p: types.Primitive) Structural {
            return .{ .name = p.spelling(), .parameters = &.{}, .representation = p };
        }

        pub const list: Structural = .{
            .name = types.list_spelling,
            .parameters = &.{.type},
            .constructors = &.{ "Nil", "Cons" },
        };

        pub const boolean: Structural = .{
            .name = types.bool_spelling,
            .parameters = &.{},
            .constructors = &.{ "False", "True" },
        };

        pub const ordering: Structural = .{
            .name = types.ordering_spelling,
            .parameters = &.{},
            .constructors = &.{ "LT", "EQ", "GT" },
        };

        /// The primitives come first, in `Primitive` order, so each takes the id
        /// `Primitive.id` names.
        pub const all: []const Structural = &.{
            primitive(.Int),
            primitive(.String),
            primitive(.Regex),
            primitive(.Node),
            primitive(.Kind),
            Structural.list,
            Structural.boolean,
            Structural.ordering,
        };
    };

    /// Declares `Prim`'s built-in types: the aliases `Range` and `Point`, and
    /// each `Structural` row with no constructors yet. The primitive schemes
    /// mention them, so their ids must exist before `Prim` is parsed; its own
    /// declarations fill the constructors in.
    pub fn reserveBuiltins(self: *Registry, interner: *symbols.Interner) !void {
        for ([_]types.Type{ types.range_type, types.point_type }) |t| {
            try self.defineAlias(.prim, .{ .name = t.alias.spelling, .parameters = &.{}, .body = t.alias.expansion, .kind = .type });
        }
        for (Structural.all) |s| {
            const id = try self.declare(interner, .prim, s.name, s.parameters, &.{});
            if (s.representation) |p| std.debug.assert(id == p.id());
            self.datatypes.items[@intFromEnum(id)].reserved = true;
        }
    }

    /// Marks reserved `id` as declared by `Prim`.
    pub fn claim(self: *Registry, id: TypeId) void {
        self.datatypes.items[@intFromEnum(id)].reserved = false;
    }

    /// The reservation `name` names, when it names one.
    pub fn structuralNamed(name: []const u8) ?Structural {
        for (Structural.all) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn listId(self: *const Registry) TypeId {
        return self.lookup(.prim, types.list_spelling).?;
    }

    pub fn boolId(self: *const Registry) TypeId {
        return self.lookup(.prim, types.bool_spelling).?;
    }

    /// The constructor `b` denotes. `False` is tag 0 and `True` is tag 1,
    /// fixed by `Structural.boolean`; a caller building a boolean value must
    /// not assume that order itself.
    pub fn boolConstructor(self: *const Registry, b: bool) Constructor {
        return self.get(self.boolId()).constructors[if (b) 1 else 0];
    }

    pub fn orderingId(self: *const Registry) TypeId {
        return self.lookup(.prim, types.ordering_spelling).?;
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
        return .{ .variables = self.get(id).parameters, .type = try types.arrows(arena, constructor.fields, result) };
    }

    /// `id` applied to its own parameters, in order.
    pub fn applied(self: *const Registry, arena: Allocator, id: TypeId) Allocator.Error!types.Type {
        const declared = self.get(id);
        const arguments = try arena.alloc(types.Type, declared.parameters.len);
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

    /// `name`, `parameters` and the constructor slice must outlive the
    /// registry; all are expected to live in the program arena. Each constructor's symbol is
    /// pointed back at the datatype declaring it.
    pub fn declare(
        self: *Registry,
        interner: *symbols.Interner,
        module: symbols.ModuleId,
        name: []const u8,
        parameters: []const types.Kind,
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

    /// Sets the kinds of `id`'s parameters, for a type declared before they
    /// were solved. `parameters` must outlive the registry.
    pub fn setParameters(self: *Registry, id: TypeId, parameters: []const types.Kind) void {
        self.datatypes.items[@intFromEnum(id)].parameters = parameters;
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
        const stored = try self.allocator.create(Alias);
        stored.* = alias;
        try self.aliases.put(self.allocator, .{ .module = module, .name = alias.name }, stored);
    }

    /// The alias `module` declares as `name`.
    pub fn aliasNamed(self: *const Registry, module: symbols.ModuleId, name: []const u8) ?*const Alias {
        return self.aliases.get(.{ .module = module, .name = name });
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
