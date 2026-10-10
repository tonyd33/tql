//! The identity store: what every symbol in a compilation is, and what has
//! been learned about it.

const std = @import("std");
const classes = @import("classes.zig");
const datatypes = @import("datatypes.zig");
const details = @import("details.zig");
const diagnostic = @import("../diagnostic.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Symbols, declared types, and the info passes attach to them.
///
/// Identity is append-only: a symbol interned here keeps its id for the life
/// of the environment. Info is not, and a pass may fill in what an earlier one
/// left empty.
pub const Env = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    interner: symbols.Interner,
    datatypes: datatypes.Registry,
    classes: classes.Registry,
    /// The scheme of every symbol that has one: a primitive's declared scheme,
    /// or a definition's inferred one.
    schemes: symbols.SymbolTable(types.Scheme),
    /// The scheme a signature wrote, by the symbol it annotates. Kept apart
    /// from `schemes` so a written signature can be checked against what
    /// inference found.
    annotations: symbols.SymbolTable(Annotation),
    /// Definitions the simplifier inlines at every saturated call, whatever
    /// their size.
    always_inline: symbols.SymbolTable(void),
    /// The symbol each `Known` names. Null until a library module exports it.
    known: std.EnumArray(symbols.Known, ?symbols.SymbolId) = .initFill(null),
    /// The symbol each primitive is interned as. Null before the primitives
    /// are populated.
    primitives: std.EnumArray(details.PrimOp, ?symbols.SymbolId) = .initFill(null),
    /// The tuple datatype of each arity declared so far.
    tuples: [types.max_tuple_arity + 1]?symbols.TypeId = @splat(null),

    /// A written signature, translated.
    pub const Annotation = struct {
        scheme: types.Scheme,
        span: diagnostic.Span,
    };

    /// Declares `Prim` as `ModuleId.prim`, and reserves the classes the
    /// engine names in it.
    pub fn init(gpa: Allocator) !Env {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const scratch = arena.allocator();
        var interner = symbols.Interner.init(scratch);
        _ = try interner.declareModule(symbols.ModuleId.prim_name);
        var class_registry = classes.Registry.init(scratch);
        try class_registry.reserveBuiltins();
        return .{
            .gpa = gpa,
            .arena = arena,
            .interner = interner,
            .datatypes = datatypes.Registry.init(scratch),
            .classes = class_registry,
            .schemes = symbols.SymbolTable(types.Scheme).init(scratch),
            .annotations = symbols.SymbolTable(Annotation).init(scratch),
            .always_inline = symbols.SymbolTable(void).init(scratch),
        };
    }

    /// A copy with its own arena. It shares what `self` allocated, so `self`
    /// must outlive it and not change while it lives.
    pub fn clone(self: *const Env, gpa: Allocator) !Env {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const scratch = arena.allocator();
        return .{
            .gpa = gpa,
            .arena = arena,
            .interner = try self.interner.clone(scratch),
            .datatypes = try self.datatypes.clone(scratch),
            .classes = try self.classes.clone(scratch),
            .schemes = try self.schemes.clone(scratch),
            .annotations = try self.annotations.clone(scratch),
            .always_inline = try self.always_inline.clone(scratch),
            .known = self.known,
            .primitives = self.primitives,
            .tuples = self.tuples,
        };
    }

    pub fn deinit(self: *Env) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Where info attached to a symbol must be allocated.
    pub fn allocator(self: *const Env) Allocator {
        return self.arena.allocator();
    }

    pub fn schemeOf(self: *const Env, id: symbols.SymbolId) ?types.Scheme {
        return self.schemes.get(id);
    }

    pub fn setScheme(self: *Env, id: symbols.SymbolId, scheme: types.Scheme) Allocator.Error!void {
        try self.schemes.put(id, scheme);
    }

    /// The datatype of tuples with `arity` components, declared in `Prim`
    /// the first time it is asked for with `Eq`, `Ord` and `Serial`, each
    /// requiring its class of every component. Its constructor is spelled as
    /// the type, and no name lookup finds it.
    ///
    /// Preconditions:
    /// - `arity` is not one.
    /// - `Prim` has declared its classes.
    pub fn tuple(self: *Env, arity: types.TypeVar) Allocator.Error!symbols.TypeId {
        if (self.tuples[arity]) |id| return id;

        const scratch = self.allocator();
        const name = try scratch.alloc(u8, if (arity == 0) 2 else arity + 1);
        name[0] = '(';
        @memset(name[1 .. name.len - 1], ',');
        name[name.len - 1] = ')';
        const parameters = try scratch.alloc(types.Kind, arity);
        @memset(parameters, .type);
        const id = try self.datatypes.declare(&self.interner, .prim, name, parameters, &.{}, .tuple);
        self.tuples[arity] = id;

        const fields = try scratch.alloc(types.Type, arity);
        for (fields, 0..) |*field, i| field.* = types.variable_type(@intCast(i));
        try self.setConstructors(id, try scratch.dupe(datatypes.Constructor, &.{.{
            .symbol = try self.interner.generate(.prim, name, .vanilla),
            .tag = 0,
            .fields = fields,
        }}));

        for ([_]classes.ClassId{ .eq, .ord, .serial }) |class| {
            const context = try scratch.alloc(classes.Requirement, arity);
            for (context, 0..) |*requirement, i| requirement.* = .{ .class = class, .variable = @intCast(i) };
            _ = try self.declareInstance(.{
                .class = class,
                .type = try self.datatypes.applied(scratch, id),
                .context = context,
                .methods = &.{},
                .dictionary = undefined,
                .module = .prim,
            });
        }
        return id;
    }

    /// Fill in the constructors of `id`, declared with none yet, and give
    /// each its scheme.
    pub fn setConstructors(
        self: *Env,
        id: symbols.TypeId,
        constructors: []const datatypes.Constructor,
    ) Allocator.Error!void {
        self.datatypes.setConstructors(&self.interner, id, constructors);
        for (constructors) |c| {
            try self.setScheme(c.symbol, try self.datatypes.constructorScheme(self.allocator(), id, c));
        }
    }

    /// Adds `declared`, with a generated `instance[C,T]` dictionary when its
    /// class takes one and a generated `m[T]` for each method `m`. Returns
    /// the instance already declared for its class and head instead, adding
    /// nothing, when there is one.
    pub fn declareInstance(self: *Env, declared: classes.Instance) Allocator.Error!classes.Registry.Addition {
        var instance = declared;
        instance.dictionary = switch (self.classes.evidenceOf(declared.class)) {
            .builtin => null,
            .dictionary => try self.interner.generate(
                declared.module,
                try std.fmt.allocPrint(self.allocator(), "instance[{s},{s}]", .{ self.classes.spelling(declared.class), self.datatypes.get(declared.head()).name }),
                .vanilla,
            ),
        };
        const addition = try self.classes.addInstance(instance);
        const id = switch (addition) {
            .added => |id| id,
            .existing => return addition,
        };
        if (instance.dictionary) |dictionary| self.interner.setDetails(dictionary, .{ .instance = id });
        const class_methods = self.classes.get(declared.class).methods;
        const methods = try self.allocator().alloc(symbols.SymbolId, class_methods.len);
        for (class_methods, methods, 0..) |method, *symbol, i| {
            symbol.* = try self.interner.generate(
                declared.module,
                try std.fmt.allocPrint(self.allocator(), "{s}[{s}]", .{ self.interner.spelling(method), self.datatypes.get(declared.head()).name }),
                .{ .instance_method = .{ .instance = id, .index = @intCast(i) } },
            );
        }
        self.classes.instanceMut(id).methods = methods;
        return addition;
    }

    pub fn annotationOf(self: *const Env, id: symbols.SymbolId) ?Annotation {
        return self.annotations.get(id);
    }

    pub fn annotate(self: *Env, symbol: symbols.SymbolId, a: Annotation) Allocator.Error!void {
        try self.annotations.put(symbol, a);
    }

    pub fn markAlwaysInline(self: *Env, symbol: symbols.SymbolId) Allocator.Error!void {
        try self.always_inline.put(symbol, {});
    }

    pub fn alwaysInlines(self: *const Env, symbol: symbols.SymbolId) bool {
        return self.always_inline.get(symbol) != null;
    }
};
