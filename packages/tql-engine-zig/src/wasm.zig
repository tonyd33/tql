const std = @import("std");
const tql = @import("tql_engine_zig");

const gpa = std.heap.wasm_allocator;

pub fn main() void {}

var last_result: std.Io.Writer.Allocating = undefined;
var last_error: std.Io.Writer.Allocating = undefined;
var initialized: bool = false;

fn ensureInit() void {
    if (initialized) return;
    last_result = std.Io.Writer.Allocating.init(gpa);
    last_error = std.Io.Writer.Allocating.init(gpa);
    initialized = true;
}

export fn tql_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn tql_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

export fn tql_last_result_ptr() [*]const u8 {
    ensureInit();
    return last_result.written().ptr;
}

export fn tql_last_result_len() usize {
    ensureInit();
    return last_result.written().len;
}

export fn tql_last_error_ptr() [*]const u8 {
    ensureInit();
    return last_error.written().ptr;
}

export fn tql_last_error_len() usize {
    ensureInit();
    return last_error.written().len;
}

export fn tql_run(
    language_id: u32,
    query_ptr: [*]const u8,
    query_len: usize,
    target_ptr: [*]const u8,
    target_len: usize,
) i32 {
    ensureInit();
    last_result.clearRetainingCapacity();
    last_error.clearRetainingCapacity();

    const language: tql.Language = switch (language_id) {
        0 => .c,
        1 => .typescript,
        2 => .tsx,
        else => {
            writeError("invalid language id");
            return 1;
        },
    };

    runImpl(language, query_ptr[0..query_len], target_ptr[0..target_len]) catch |err| {
        writeError(@errorName(err));
        return 2;
    };
    return 0;
}

fn runImpl(language: tql.Language, query_source: []const u8, query_target: []const u8) !void {
    var engine = try tql.Engine.init(.{ .allocator = gpa });
    defer engine.deinit();

    var compiled = try engine.compile(query_source, language);
    defer compiled.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var run_result = try compiled.run(query_target, arena.allocator(), arena.allocator());
    defer run_result.deinit();

    var jws: std.json.Stringify = .{ .writer = &last_result.writer };
    try jws.beginObject();
    try jws.objectField("values");
    try jws.beginArray();
    for (run_result.values.items) |v| try v.jsonStringify(&jws);
    try jws.endArray();
    try jws.objectField("stats");
    try jws.beginObject();
    try jws.objectField("parse_time_ns");
    try jws.write(run_result.stats.parse_time_ns);
    try jws.objectField("query_time_ns");
    try jws.write(run_result.stats.query_time_ns);
    try jws.endObject();
    try jws.endObject();
}

fn writeError(msg: []const u8) void {
    last_error.writer.writeAll(msg) catch {};
}
