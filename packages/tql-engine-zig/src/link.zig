//! Assembles desugared Core modules into a `Program`.
//!
//! Modules link in order, the entry module last. Definitions are concatenated
//! and each module's edges renumbered into linked indices before Tarjan runs once
//! over the merged graph. Per-module SCCs would hold only while no cycle
//! crosses a module boundary and modules arrive in dependency order; one
//! whole-program pass does not depend on either.

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");
const resolve = @import("resolve.zig");
const desugar = @import("desugar.zig");
const primitives = @import("primitives.zig");
const symbols = @import("symbols.zig");

pub const Error = error{LinkFailed} || std.mem.Allocator.Error;

/// A linked program: definitions, the SCCs type checking consumes, and the
/// entrypoint.
///
/// Terms and the strings they reference live in `arena`, which is heap-owned so
/// the program can be returned by value: an `ArenaAllocator`'s allocator holds
/// a pointer to the arena itself, which moving the struct would dangle.
pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    definitions: []const core.Definition,
    /// Indices into `definitions`, grouped by strongly connected component in
    /// dependency order.
    components: []const []const u32,
    /// The linked program's `main`.
    entry: symbols.SymbolId,
    /// Where the entry module's definitions begin; everything below it was
    /// linked in from a library module.
    entry_offset: u32,
    interner: symbols.Interner,
    primitives: primitives.Table,
    /// What each synthesized symbol was generated from, merged from the linked
    /// modules. Desugaring's output: nothing downstream has the grammar.
    synthesis: desugar.SynthesisTable,

    /// The definitions the entry module declared, in declaration order.
    pub fn entryDefinitions(self: *const Program) []const core.Definition {
        return self.definitions[self.entry_offset..];
    }

    pub fn deinit(self: *Program) void {
        self.synthesis.deinit();
        self.primitives.deinit();
        self.interner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

/// One `name = term` line per definition the entry module declared, in
/// declaration order. Library definitions linked in beneath it are omitted.
pub fn printProgram(
    p: *const Program,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const printer: core.Printer = .{ .interner = &p.interner };
    for (p.entryDefinitions(), 0..) |d, i| {
        if (i > 0) try w.writeByte('\n');
        try w.print("{s} = ", .{p.interner.spelling(d.symbol)});
        try printer.term(d.body, w);
    }
}

/// Owns a link in progress: the arena every module's terms are desugared into,
/// the symbol identities they share, and the modules added so far.
///
/// Modules are added in link order, the entry module last. Ownership of the
/// arena, the interner, and the tables passes to the program `finish` returns.
/// Until then, and on any failure, `deinit` releases them.
pub const Linker = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    interned: primitives.Interned,
    /// Shared across every module in the link, so a symbol is one symbol
    /// whichever module synthesized it.
    synthesis: desugar.SynthesisTable,
    modules: std.ArrayList(desugar.Module) = .empty,
    // HACK: there's likely a better way of memory safety
    owns: bool = true,

    pub fn init(allocator: std.mem.Allocator) !Linker {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        return .{
            .allocator = allocator,
            .arena = arena,
            .interned = try primitives.Interned.init(allocator),
            .synthesis = desugar.SynthesisTable.init(allocator),
        };
    }

    /// The identities every module in this link is desugared against.
    pub fn interner(self: *Linker) *symbols.Interner {
        return &self.interned.interner;
    }

    pub fn deinit(self: *Linker) void {
        self.modules.deinit(self.allocator);
        if (!self.owns) return;
        self.synthesis.deinit();
        self.interned.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn add(self: *Linker, m: desugar.Module) std.mem.Allocator.Error!void {
        try self.modules.append(self.allocator, m);
    }

    /// Assembles the added modules into a program. The last one added is the
    /// entry module and must declare `main`.
    pub fn finish(
        self: *Linker,
        entry_span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) Error!Program {
        std.debug.assert(self.modules.items.len > 0);

        const scratch = self.arena.allocator();

        var total: usize = 0;
        for (self.modules.items) |m| total += m.definitions.len;

        const definitions = try scratch.alloc(core.Definition, total);
        const edges = try scratch.alloc([]const u32, total);

        var offset: u32 = 0;
        var entry_offset: u32 = 0;
        for (self.modules.items, 0..) |m, i| {
            if (i + 1 == self.modules.items.len) entry_offset = offset;
            offset += try place(scratch, m, definitions, edges, offset);
        }

        const main = try entrySymbol(
            definitions[entry_offset..],
            &self.interned.interner,
            entry_span,
            sink,
        );

        var components_result = try resolve.stronglyConnectedComponents(self.allocator, edges);
        defer components_result.deinit();

        const components = try scratch.alloc([]const u32, components_result.groups.len);
        for (components_result.groups, 0..) |c, i| {
            components[i] = try scratch.dupe(u32, c);
        }

        self.owns = false;
        return .{
            .allocator = self.allocator,
            .arena = self.arena,
            .definitions = definitions,
            .components = components,
            .entry = main,
            .entry_offset = entry_offset,
            .interner = self.interned.interner,
            .primitives = self.interned.table,
            .synthesis = self.synthesis,
        };
    }
};

/// Copies one module's definitions in at `offset`, shifting its module-local
/// edges into linked indices. Returns how many it placed.
fn place(
    scratch: std.mem.Allocator,
    m: desugar.Module,
    definitions: []core.Definition,
    edges: [][]const u32,
    offset: u32,
) std.mem.Allocator.Error!u32 {
    for (m.definitions, 0..) |d, i| definitions[offset + i] = d;

    for (m.edges, 0..) |module_local, i| {
        const shifted = try scratch.alloc(u32, module_local.len);
        for (module_local, 0..) |target, j| shifted[j] = target + offset;
        edges[offset + i] = shifted;
    }

    return @intCast(m.definitions.len);
}

/// `main` must be declared by the entry module. Its type — and with it the
/// rejection of a `main` that returns a function — is inference's.
fn entrySymbol(
    entry_definitions: []const core.Definition,
    interner: *const symbols.Interner,
    entry_span: diagnostic.Span,
    sink: *diagnostic.Sink,
) Error!symbols.SymbolId {
    for (entry_definitions) |d| {
        if (std.mem.eql(u8, interner.spelling(d.symbol), "main")) return d.symbol;
    }

    try sink.report(.missing_main, entry_span, "no `main` definition", .{});
    return error.LinkFailed;
}
