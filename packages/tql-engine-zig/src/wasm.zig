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

export fn tql_run(
    language_id: u32,
    query_ptr: [*]const u8,
    query_len: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);
    errdefer buf.deinit();

    const language: tql.Language = switch (language_id) {
        0 => .cpp,
        1 => .c,
        2 => .go,
        3 => .javascript,
        4 => .python,
        5 => .rust,
        6 => .tsx,
        7 => .typescript,
        8 => .zig,
        else => return finishErr(&buf, out, "invalid language id"),
    };

    runImpl(language, query_ptr[0..query_len], target_ptr[0..target_len], &buf) catch |err| {
        return finishErr(&buf, out, @errorName(err));
    };

    const slice = buf.toOwnedSlice() catch return fail(out);
    out.* = .{ .status = 0, .ptr = slice.ptr, .len = slice.len };
}

fn runImpl(
    language: tql.Language,
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

    var compiled = try engine.compile(query_source, language);
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
