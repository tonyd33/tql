const std = @import("std");
const engine_mod = @import("engine");
const ts = engine_mod.ts;
const RuntimeMod = engine_mod.Runtime;
const Value = engine_mod.Value;

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

pub fn formatAst(allocator: std.mem.Allocator, ast: engine_mod.ast.SourceFile) ![]const u8 {
    return ast.sexprAlloc(allocator);
}

pub fn formatSourceAst(allocator: std.mem.Allocator, tree: *ts.Tree) ![]const u8 {
    return tree.rootNode().toSexp(allocator);
}

pub fn formatBytecode(allocator: std.mem.Allocator, instructions: []const RuntimeMod.Instruction) ![]const u8 {
    var buf = try std.Io.Writer.Allocating.initCapacity(allocator, 10 * 1024 * 1024);
    defer buf.deinit();

    for (instructions, 0..) |inst, i| {
        try buf.writer.print("{d:0>4}: ", .{i});
        try inst.print(&buf.writer);
        try buf.writer.writeByte('\n');
    }

    return try buf.toOwnedSlice();
}

pub fn formatValues(allocator: std.mem.Allocator, values: []const Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    const writer = &w.writer;

    var jws = std.json.Stringify{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try jws.beginArray();
    for (values) |v| {
        try jws.write(v);
    }
    try jws.endArray();

    return try w.toOwnedSlice();
}
