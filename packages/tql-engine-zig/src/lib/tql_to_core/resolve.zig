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
        /// Null for `_`, which no lookup finds.
        name: ?[]const u8,
        symbol: core.SymbolId,
    };

    pub fn lookup(self: *const Scope, name: []const u8) ?core.SymbolId {
        var frame: ?*const Scope = self;
        while (frame) |f| : (frame = f.parent) {
            for (f.names) |entry| {
                if (std.mem.eql(u8, entry.name orelse continue, name)) return entry.symbol;
            }
        }
        return null;
    }
};

/// A collected top-level declaration: its name, the symbol of the definition
/// it binds, and what it is.
pub const Declaration = struct {
    /// Null for a definition of `_`, which no name reaches.
    name: ?[]const u8,
    /// A value's own symbol, or a pattern synonym's matcher.
    symbol: core.SymbolId,
    kind: Kind,

    pub const Kind = union(enum) {
        value: struct {
            definition: *const cst.Definition,
            signature: ?*const cst.Signature = null,
        },
        synonym: struct {
            declaration: *const cst.PatternSynonym,
            signature: ?*const cst.PatternSignature = null,
            /// The symbol a pattern names the synonym by.
            pattern: core.SymbolId,
        },
    };

    pub fn span(self: Declaration) diagnostic.Span {
        return switch (self.kind) {
            .value => |v| v.definition.span,
            .synonym => |s| s.declaration.span,
        };
    }
};

pub const Declarations = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Declaration) = .empty,

    pub fn deinit(self: *Declarations) void {
        self.items.deinit(self.allocator);
    }

    fn find(self: *Declarations, name: []const u8) ?*Declaration {
        for (self.items.items) |*d| {
            if (std.mem.eql(u8, d.name orelse continue, name)) return d;
        }
        return null;
    }
};

/// Walks declarations, interning each head under `module` and pairing
/// signatures with definitions and pattern synonyms. Every problem found is
/// reported; collection continues so one run reports them all.
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
        const name, const span = switch (decl.*) {
            .definition => |*d| .{ d.name, d.span },
            .pattern_synonym => |*s| .{ s.name, s.span },
            else => continue,
        };

        if (name) |n| if (declarations.find(n)) |_| {
            try sink.report(.duplicate_definition, span, "`{s}` is defined more than once", .{n});
            continue;
        };

        const declaration = intern(interner, module, decl) catch |err| switch (err) {
            error.Collision => {
                try sink.report(.symbol_collision, span, "`{s}` collides with an existing symbol", .{name orelse "_"});
                continue;
            },
            else => |e| return e,
        };
        try declarations.items.append(allocator, declaration);
    }

    for (source.declarations) |*decl| {
        const name, const span, const noun = switch (decl.*) {
            .signature => |*s| .{ s.name, s.span, "definition" },
            .pattern_signature => |*s| .{ s.name, s.span, "pattern synonym" },
            else => continue,
        };

        const target = declarations.find(name) orelse {
            if (interner.lookup(module, name)) |_| {
                try sink.report(.symbol_collision, span, "`{s}` collides with an existing symbol", .{name});
                continue;
            }
            try sink.report(.orphan_signature, span, "`{s}` has a signature but no {s}", .{ name, noun });
            continue;
        };

        // A value's name and a pattern synonym's never coincide.
        const attached = switch (decl.*) {
            .signature => |*s| attach(cst.Signature, &target.kind.value.signature, s),
            .pattern_signature => |*s| attach(cst.PatternSignature, &target.kind.synonym.signature, s),
            else => unreachable,
        };
        if (!attached) {
            try sink.report(.duplicate_signature, span, "`{s}` has more than one signature", .{name});
        }
    }

    return declarations;
}

/// Intern the head `decl` declares. A pattern synonym `P` interns its matcher
/// `$mP` too.
fn intern(interner: *core.Interner, module: core.ModuleId, decl: *const cst.Declaration) !Declaration {
    switch (decl.*) {
        .definition => |*d| return .{
            .name = d.name,
            .symbol = if (d.name) |name| try interner.intern(module, name, .vanilla) else try interner.fresh("_"),
            .kind = .{ .value = .{ .definition = d } },
        },
        .pattern_synonym => |*s| {
            if (interner.lookup(module, s.name) != null) return error.Collision;
            const spelling = try std.fmt.allocPrint(interner.allocator, "$m{s}", .{s.name});
            defer interner.allocator.free(spelling);
            const matcher = try interner.intern(module, spelling, .{ .matcher = .{ .arity = @intCast(s.parameters.len) } });
            const pattern = try interner.intern(module, s.name, .{ .synonym = .{ .matcher = matcher } });
            return .{
                .name = s.name,
                .symbol = matcher,
                .kind = .{ .synonym = .{ .declaration = s, .pattern = pattern } },
            };
        },
        else => unreachable,
    }
}

/// Attach `signature` to `slot`. Returns false when `slot` already holds one.
fn attach(comptime T: type, slot: *?*const T, signature: *const T) bool {
    if (slot.* != null) return false;
    slot.* = signature;
    return true;
}
