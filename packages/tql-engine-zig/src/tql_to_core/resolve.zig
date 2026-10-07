//! Scopes and declaration collection.
//!
//! Declaration heads and signatures are collected before any body is resolved,
//! so forward references are valid. Bodies resolve lexically first, then
//! globally.

const std = @import("std");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");

/// A lexical scope chain. Each frame is one binding construct: lambda
/// parameters, a `let` group, a `do` bind, or a `do`-local `let` group.
pub const Scope = struct {
    parent: ?*const Scope,
    names: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        symbol: core.SymbolId,
    };

    pub fn lookup(self: *const Scope, name: []const u8) ?core.SymbolId {
        var frame: ?*const Scope = self;
        while (frame) |f| : (frame = f.parent) {
            // Later entries in a frame shadow earlier ones, which matters for
            // `\x x -> e`.
            var i = f.names.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, f.names[i].name, name)) return f.names[i].symbol;
            }
        }
        return null;
    }
};

/// A collected top-level declaration: the definition, its symbol, and the
/// signature that annotates it, if any.
pub const Declaration = struct {
    name: []const u8,
    symbol: core.SymbolId,
    definition: *const cst.Definition,
    signature: ?*const cst.Signature = null,
};

/// A collected pattern synonym: the declaration, its symbol, and the
/// signature that annotates it, if any.
pub const Synonym = struct {
    name: []const u8,
    symbol: core.SymbolId,
    declaration: *const cst.PatternSynonym,
    signature: ?*const cst.PatternSignature = null,
};

pub const Declarations = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Declaration) = .empty,
    synonyms: std.ArrayList(Synonym) = .empty,

    pub fn deinit(self: *Declarations) void {
        self.items.deinit(self.allocator);
        self.synonyms.deinit(self.allocator);
    }

    pub fn find(self: *const Declarations, name: []const u8) ?*const Declaration {
        for (self.items.items) |*d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }
};

/// Walks declarations, interning each head under `module` and pairing
/// signatures with definitions. Every problem found is reported; collection
/// continues so one run reports them all.
pub fn collect(
    allocator: std.mem.Allocator,
    interner: *core.Interner,
    module: core.ModuleId,
    source: cst.SourceFile,
    sink: *diagnostic.Sink,
) !Declarations {
    var declarations: Declarations = .{ .allocator = allocator };
    errdefer declarations.deinit();

    // Captured by pointer into the array: iterating by value would copy the
    // element, and a pointer into that copy dies with the iteration.
    for (source.declarations) |*decl| {
        if (decl.* != .definition) continue;
        const definition = &decl.definition;

        if (declarations.find(definition.name)) |_| {
            try sink.report(
                .duplicate_definition,
                definition.span,
                "`{s}` is defined more than once",
                .{definition.name},
            );
            continue;
        }

        const symbol = interner.intern(module, definition.name, .vanilla) catch |err| switch (err) {
            error.Collision => {
                try sink.report(
                    .symbol_collision,
                    definition.span,
                    "`{s}` collides with an existing symbol",
                    .{definition.name},
                );
                continue;
            },
            else => |e| return e,
        };

        try declarations.items.append(allocator, .{
            .name = definition.name,
            .symbol = symbol,
            .definition = definition,
        });
    }

    for (source.declarations) |*decl| {
        if (decl.* != .signature) continue;
        const signature = &decl.signature;

        const target = for (declarations.items.items) |*d| {
            if (std.mem.eql(u8, d.name, signature.name)) break d;
        } else {
            if (interner.lookup(module, signature.name)) |_| {
                try sink.report(
                    .symbol_collision,
                    signature.span,
                    "`{s}` collides with an existing symbol",
                    .{signature.name},
                );
                continue;
            }
            try sink.report(
                .orphan_signature,
                signature.span,
                "`{s}` has a signature but no definition",
                .{signature.name},
            );
            continue;
        };

        if (target.signature != null) {
            try sink.report(
                .duplicate_signature,
                signature.span,
                "`{s}` has more than one signature",
                .{signature.name},
            );
            continue;
        }
        target.signature = signature;
    }

    try collectSynonyms(&declarations, interner, module, source, sink);
    return declarations;
}

fn collectSynonyms(
    declarations: *Declarations,
    interner: *core.Interner,
    module: core.ModuleId,
    source: cst.SourceFile,
    sink: *diagnostic.Sink,
) !void {
    for (source.declarations) |*decl| {
        if (decl.* != .pattern_synonym) continue;
        const synonym = &decl.pattern_synonym;

        const repeated = for (declarations.synonyms.items) |earlier| {
            if (std.mem.eql(u8, earlier.name, synonym.name)) break true;
        } else false;
        if (repeated) {
            try sink.report(
                .duplicate_definition,
                synonym.span,
                "`{s}` is defined more than once",
                .{synonym.name},
            );
            continue;
        }

        const arity: u32 = @intCast(synonym.parameters.len);
        const symbol = interner.intern(module, synonym.name, .{ .synonym = .{ .arity = arity } }) catch |err| switch (err) {
            error.Collision => {
                try sink.report(
                    .symbol_collision,
                    synonym.span,
                    "`{s}` collides with an existing symbol",
                    .{synonym.name},
                );
                continue;
            },
            else => |e| return e,
        };

        try declarations.synonyms.append(declarations.allocator, .{
            .name = synonym.name,
            .symbol = symbol,
            .declaration = synonym,
        });
    }

    for (source.declarations) |*decl| {
        if (decl.* != .pattern_signature) continue;
        const signature = &decl.pattern_signature;

        const target = for (declarations.synonyms.items) |*s| {
            if (std.mem.eql(u8, s.name, signature.name)) break s;
        } else {
            try sink.report(
                .orphan_signature,
                signature.span,
                "`{s}` has a signature but no pattern synonym",
                .{signature.name},
            );
            continue;
        };

        if (target.signature != null) {
            try sink.report(
                .duplicate_signature,
                signature.span,
                "`{s}` has more than one signature",
                .{signature.name},
            );
            continue;
        }
        target.signature = signature;
    }
}

test "scopes resolve innermost first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var interner = core.Interner.init(arena.allocator());

    const outer_x = try interner.fresh("x");
    const inner_x = try interner.fresh("x");

    const outer: Scope = .{ .parent = null, .names = &.{.{ .name = "x", .symbol = outer_x }} };
    const inner: Scope = .{ .parent = &outer, .names = &.{.{ .name = "x", .symbol = inner_x }} };

    try std.testing.expectEqual(inner_x, inner.lookup("x").?);
    try std.testing.expectEqual(outer_x, outer.lookup("x").?);
    try std.testing.expectEqual(null, inner.lookup("y"));
}
