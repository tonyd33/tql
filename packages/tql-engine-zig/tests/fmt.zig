const std = @import("std");
const tql = @import("tql");
const ts = tql.ts;

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const green = "\x1b[32m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
    pub const green_bold = "\x1b[1;32m";
    pub const red_bold = "\x1b[1;31m";
    pub const yellow_bold = "\x1b[1;33m";
};

pub fn formatCst(allocator: std.mem.Allocator, tree: tql.cst.SourceFile) ![]const u8 {
    return tree.sexprAlloc(allocator);
}

pub fn formatCore(allocator: std.mem.Allocator, program: *const tql.core.Program) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    try tql.core.printProgram(program, &w.writer);
    return w.toOwnedSlice();
}

/// The entry module's definitions as translated to STG.
pub fn formatStg(
    allocator: std.mem.Allocator,
    program: *const tql.core.Program,
    translated: *const tql.stg.Program,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    const printer: tql.stg.Printer = .{ .interner = &program.env.interner };
    try printer.definitions(translated.definitions[program.entry_offset..program.entry_end], &w.writer);
    return w.toOwnedSlice();
}

/// `name :: scheme` per entry-module definition, in declaration order, less
/// those generated for instances.
///
/// Entry definitions only, like `formatCore`: the library's schemes are
/// asserted in a `root.zig` test instead, so a library edit does not rewrite
/// every fixture's types section.
pub fn formatTypes(
    allocator: std.mem.Allocator,
    program: *const tql.core.Program,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();

    var first = true;
    var named = program.namedDefinitions();
    while (named.next()) |definition| {
        if (!first) try w.writer.writeByte('\n');
        first = false;
        try w.writer.print("{s} :: ", .{program.env.interner.spelling(definition.symbol)});
        const scheme = program.env.schemeOf(definition.symbol) orelse {
            try w.writer.writeAll("<unchecked>");
            continue;
        };
        try scheme.named(&program.env.classes).format(&w.writer);
    }
    return w.toOwnedSlice();
}

pub fn formatSourceAst(allocator: std.mem.Allocator, tree: *ts.Tree) ![]const u8 {
    return tree.rootNode().toSexp(allocator);
}
