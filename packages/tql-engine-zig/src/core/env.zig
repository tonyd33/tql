//! The identity store: what every symbol in a compilation is, and what has
//! been learned about it.

const std = @import("std");
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
    /// The symbol each primitive is interned as. Null before the primitives
    /// are populated.
    primitives: std.EnumArray(details.PrimOp, ?symbols.SymbolId) = .initFill(null),

    /// A written signature, translated.
    pub const Annotation = struct {
        scheme: types.Scheme,
        span: diagnostic.Span,
    };

    /// Declares `Prelude` as `ModuleId.prelude`.
    pub fn init(gpa: Allocator) !Env {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const scratch = arena.allocator();
        var interner = symbols.Interner.init(scratch);
        _ = try interner.declareModule(symbols.ModuleId.prelude_name);
        return .{
            .gpa = gpa,
            .arena = arena,
            .interner = interner,
            .datatypes = datatypes.Registry.init(scratch),
            .schemes = symbols.SymbolTable(types.Scheme).init(scratch),
            .annotations = symbols.SymbolTable(Annotation).init(scratch),
            .always_inline = symbols.SymbolTable(void).init(scratch),
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
