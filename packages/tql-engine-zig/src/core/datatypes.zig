//! Declared algebraic data types and their constructors.

const std = @import("std");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const TypeId = symbols.TypeId;

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

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// What the machine expects of a type it builds values of directly.
    ///
    /// The prelude declares `List` and `Bool`; these rows reserve their ids
    /// and class entailments so a primitive scheme can name either before the
    /// prelude is parsed.
    pub const Structural = struct {
        name: []const u8,
        parameters: u8,
        classes: ClassRow,
        /// Constructor spellings in tag order.
        constructors: []const []const u8,

        pub const list: Structural = .{
            .name = types.list_spelling,
            .parameters = 1,
            .classes = .{ .Eq = .fields, .Sized = .always, .Serial = .fields },
            .constructors = &.{ "Nil", "Cons" },
        };

        pub const boolean: Structural = .{
            .name = types.bool_spelling,
            .parameters = 0,
            .classes = .{ .Eq = .always, .Serial = .always },
            .constructors = &.{ "False", "True" },
        };

        pub const all: []const Structural = &.{ Structural.list, Structural.boolean };
    };

    /// Reserves `List` and `Bool`, with no constructors yet. The primitive
    /// schemes mention both, so their ids must exist before `prelude.tql` is
    /// parsed; the prelude's own declarations fill the constructors in.
    pub fn reserveStructural(self: *Registry, interner: *symbols.Interner) !void {
        for (Structural.all) |s| {
            _ = try self.declare(interner, s.name, s.parameters, &.{}, s.classes);
        }
    }

    /// The reservation `name` names, when it names one.
    pub fn structuralNamed(name: []const u8) ?Structural {
        for (Structural.all) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Reserves `List` and `Bool` and fills in their constructors, standing in
    /// for the prelude declarations that normally do it. For a caller that
    /// needs the structural types without parsing a prelude.
    pub fn declareStructural(
        self: *Registry,
        interner: *symbols.Interner,
        arena: Allocator,
    ) !void {
        try self.reserveStructural(interner);

        const element = types.variable_type(0);
        const self_ref = try types.constructed(
            arena,
            self.listId(),
            types.list_spelling,
            &.{element},
        );
        const cons_fields = try arena.dupe(types.Type, &.{ element, self_ref });
        self.setConstructors(interner, self.listId(), try arena.dupe(Constructor, &.{
            .{ .symbol = try interner.intern("Nil", .vanilla), .tag = 0, .fields = &.{} },
            .{ .symbol = try interner.intern("Cons", .vanilla), .tag = 1, .fields = cons_fields },
        }));

        self.setConstructors(interner, self.boolId(), try arena.dupe(Constructor, &.{
            .{ .symbol = try interner.intern("False", .vanilla), .tag = 0, .fields = &.{} },
            .{ .symbol = try interner.intern("True", .vanilla), .tag = 1, .fields = &.{} },
        }));
    }

    pub fn listId(self: *const Registry) TypeId {
        return self.lookup(types.list_spelling).?;
    }

    pub fn boolId(self: *const Registry) TypeId {
        return self.lookup(types.bool_spelling).?;
    }

    /// The constructor `b` denotes. `False` is tag 0 and `True` is tag 1,
    /// fixed by `declareStructural`; a caller building a boolean value must
    /// not assume that order itself.
    pub fn boolConstructor(self: *const Registry, b: bool) Constructor {
        return self.get(self.boolId()).constructors[if (b) 1 else 0];
    }

    /// `Nil`, tag 0 of `List`.
    pub fn nilConstructor(self: *const Registry) Constructor {
        return self.get(self.listId()).constructors[0];
    }

    /// `Cons`, tag 1 of `List`, taking a head and a tail.
    pub fn consConstructor(self: *const Registry) Constructor {
        return self.get(self.listId()).constructors[1];
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

    /// `name` and the constructor slice must outlive the registry; both are
    /// expected to live in the program arena. Each constructor's symbol is
    /// pointed back at the datatype declaring it.
    pub fn declare(
        self: *Registry,
        interner: *symbols.Interner,
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

    pub fn lookup(self: *const Registry, name: []const u8) ?TypeId {
        return self.by_name.get(name);
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

test "a declared type is reachable by name, id, and constructor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    var interner = symbols.Interner.init(arena.allocator());

    const nil = try interner.intern("Nil", .vanilla);
    const cons = try interner.intern("Cons", .vanilla);
    const other = try interner.intern("other", .vanilla);
    const constructors = [_]Constructor{
        .{ .symbol = nil, .tag = 0, .fields = &.{} },
        .{ .symbol = cons, .tag = 1, .fields = &.{} },
    };

    const id = try registry.declare(&interner, "List", 1, &constructors, .{
        .Eq = .fields,
        .Sized = .always,
        .Serial = .fields,
    });

    try std.testing.expectEqual(id, registry.lookup("List").?);
    try std.testing.expectEqual(1, registry.get(id).parameters);
    try std.testing.expectEqual(id, ownerOf(&interner, cons).?);
    try std.testing.expectEqual(1, registry.constructorOf(&interner, cons).?.tag);
    try std.testing.expectEqual(null, ownerOf(&interner, other));
}

test "the structural accessors follow the declared tag order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    var interner = symbols.Interner.init(arena.allocator());
    try registry.declareStructural(&interner, arena.allocator());

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
}

test "a list is Sized whatever its elements are, but Ord never" {
    const row: ClassRow = .{ .Eq = .fields, .Sized = .always, .Serial = .fields };
    try std.testing.expectEqual(Entailment.always, row.forClass(.Sized));
    try std.testing.expectEqual(Entailment.fields, row.forClass(.Eq));
    try std.testing.expectEqual(Entailment.never, row.forClass(.Ord));
}
