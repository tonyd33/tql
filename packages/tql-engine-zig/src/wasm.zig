const std = @import("std");
const tql = @import("tql_engine_zig");

const gpa = std.heap.wasm_allocator;

pub fn main() void {}

const Result = extern struct {
    status: i32,
    ptr: [*]u8,
    len: usize,
};

export fn tql_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn tql_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

fn runImpl(
    grammar: *const tql.Grammar,
    query_source: []const u8,
    query_target: []const u8,
    buf: *std.Io.Writer.Allocating,
) !void {
    var single_threaded = std.Io.Threaded.init_single_threaded;
    const io = single_threaded.io();
    var engine = try tql.Engine.init(.{
        .allocator = gpa,
        .io = io,
    });
    defer engine.deinit();

    var compiled = try engine.compile(query_source, grammar);
    defer compiled.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var run_result = try compiled.run(query_target, arena.allocator(), arena.allocator());
    defer run_result.deinit();

    var jws: std.json.Stringify = .{ .writer = &buf.writer };
    try jws.beginObject();
    try jws.objectField("values");
    try jws.beginArray();
    for (run_result.values.items) |v| try v.jsonStringify(&jws);
    try jws.endArray();
    try jws.objectField("stats");
    try jws.beginObject();
    try jws.objectField("parse_time_ns");
    try jws.write(run_result.stats.parse_time.nanoseconds);
    try jws.objectField("query_time_ns");
    try jws.write(run_result.stats.query_time.nanoseconds);
    try jws.endObject();
    try jws.endObject();
}

fn finishErr(buf: *std.Io.Writer.Allocating, out: *Result, msg: []const u8) void {
    buf.clearRetainingCapacity();
    buf.writer.writeAll(msg) catch return fail(out);
    const slice = buf.toOwnedSlice() catch return fail(out);
    out.* = .{ .status = 1, .ptr = slice.ptr, .len = slice.len };
}

fn fail(out: *Result) void {
    out.* = .{ .status = 2, .ptr = undefined, .len = 0 };
}

export fn tql_run_dynamic(
    language_ptr: usize,
    query_ptr: [*]const u8,
    query_len: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    errdefer buf.deinit();

    if (language_ptr == 0) return finishErr(&buf, out, "null language pointer");
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);
    const grammar = tql.Grammar{
        .name = "dynamic",
        .extensions = &.{},
        .language = language,
    };

    runImpl(&grammar, query_ptr[0..query_len], target_ptr[0..target_len], &buf) catch |err| {
        return finishErr(&buf, out, @errorName(err));
    };

    const slice = buf.toOwnedSlice() catch return fail(out);
    out.* = .{ .status = 0, .ptr = slice.ptr, .len = slice.len };
}

export fn tql_parse_tree(
    language_ptr: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    errdefer buf.deinit();

    if (language_ptr == 0) return finishErr(&buf, out, "null language pointer");
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);

    parseTreeImpl(language, target_ptr[0..target_len], &buf) catch |err| {
        return finishErr(&buf, out, @errorName(err));
    };

    const slice = buf.toOwnedSlice() catch return fail(out);
    out.* = .{ .status = 0, .ptr = slice.ptr, .len = slice.len };
}

fn parseTreeImpl(
    language: *const tql.ts.Language,
    target: []const u8,
    buf: *std.Io.Writer.Allocating,
) !void {
    const parser = tql.ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language);

    const tree = parser.parseString(target, null) orelse return error.SourceParseFailed;
    defer tree.destroy();

    var cursor = tree.rootNode().walk();
    defer cursor.destroy();

    var jws: std.json.Stringify = .{ .writer = &buf.writer };
    try jws.beginArray();

    var depth: u32 = 0;
    while (true) {
        const node = cursor.node();
        try jws.beginObject();
        try jws.objectField("depth");
        try jws.write(depth);
        try jws.objectField("fieldName");
        if (cursor.fieldName()) |f| try jws.write(f) else try jws.write(null);
        try jws.objectField("type");
        try jws.write(node.kind());
        try jws.objectField("isNamed");
        try jws.write(node.isNamed());
        try jws.objectField("isMissing");
        try jws.write(node.isMissing());
        try jws.objectField("startIndex");
        try jws.write(node.startByte());
        try jws.objectField("endIndex");
        try jws.write(node.endByte());
        try jws.objectField("startRow");
        try jws.write(node.startPoint().row);
        try jws.objectField("startCol");
        try jws.write(node.startPoint().column);
        try jws.objectField("endRow");
        try jws.write(node.endPoint().row);
        try jws.objectField("endCol");
        try jws.write(node.endPoint().column);
        try jws.endObject();

        if (cursor.gotoFirstChild()) {
            depth += 1;
            continue;
        }
        while (true) {
            if (cursor.gotoNextSibling()) break;
            if (!cursor.gotoParent()) {
                try jws.endArray();
                return;
            }
            depth -= 1;
        }
    }
}
