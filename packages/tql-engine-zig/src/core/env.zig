//! The identity store: what every symbol in a compilation is, and what has
//! been learned about it.

const std = @import("std");
const datatypes = @import("datatypes.zig");
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

    /// A written signature, translated.
    pub const Annotation = struct {
        symbol: symbols.SymbolId,
        scheme: types.Scheme,
        span: diagnostic.Span,
    };

    pub fn init(gpa: Allocator) !Env {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const scratch = arena.allocator();
        return .{
            .gpa = gpa,
            .arena = arena,
            .interner = symbols.Interner.init(scratch),
            .datatypes = datatypes.Registry.init(scratch),
            .schemes = symbols.SymbolTable(types.Scheme).init(scratch),
            .annotations = symbols.SymbolTable(Annotation).init(scratch),
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

    pub fn annotationOf(self: *const Env, id: symbols.SymbolId) ?Annotation {
        return self.annotations.get(id);
    }

    pub fn annotate(self: *Env, a: Annotation) Allocator.Error!void {
        try self.annotations.put(a.symbol, a);
    }
};
