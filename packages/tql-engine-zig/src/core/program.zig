//! A linked Core program: what desugaring produces and every later stage
//! reads.

const std = @import("std");
const core = @import("../core.zig");

/// A linked program: definitions, the SCCs type checking consumes, and the
/// entrypoint.
///
/// Terms and the strings they reference live in `arena`, which is heap-owned so
/// the program can be returned by value: an `ArenaAllocator`'s allocator holds
/// a pointer to the arena itself, which moving the struct would dangle.
pub const Program = struct {
    /// Symbols, declared types, and what passes have learned about them.
    /// Owns the arena every definition is allocated from.
    env: core.env.Env,
    definitions: []const core.Definition,
    /// Indices into `definitions`, grouped by strongly connected component in
    /// dependency order. A reference to a definition with a signature is not
    /// a dependency.
    components: []const []const u32,
    /// The linked program's `main`.
    entry: core.SymbolId,
    /// Where the entry module's definitions begin; everything below it was
    /// linked in from a library module.
    entry_offset: u32,

    /// The definitions the entry module declared, in declaration order.
    pub fn entryDefinitions(self: *const Program) []const core.Definition {
        return self.definitions[self.entry_offset..];
    }

    pub fn deinit(self: *Program) void {
        self.env.deinit();
    }
};

/// One `name = term` line per definition the entry module declared, in
/// declaration order. Library definitions linked in beneath it are omitted.
pub fn printProgram(
    p: *const Program,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const printer: core.Printer = .{ .interner = &p.env.interner };
    try printer.definitions(p.entryDefinitions(), w);
}
