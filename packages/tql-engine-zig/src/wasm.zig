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
    sink: *tql.diagnostic.Sink,
) !void {
    var single_threaded = std.Io.Threaded.init_single_threaded;
    const io = single_threaded.io();
    var engine = try tql.Engine.init(.{
        .allocator = gpa,
        .io = io,
    });
    defer engine.deinit();

    var compiled = try engine.compileQuery(query_source, grammar, sink);
    defer compiled.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const run_result = try compiled.run(
        query_target,
        null,
        arena.allocator(),
        arena.allocator(),
    );

    var jws: std.json.Stringify = .{ .writer = &buf.writer };
    try jws.beginObject();
    try jws.objectField("values");
    try jws.beginWriteRaw();
    try jws.writer.writeAll(run_result.json);
    jws.endWriteRaw();
    try jws.objectField("stats");
    try jws.beginObject();
    try jws.objectField("parse_time_ns");
    try jws.write(run_result.parse_time.nanoseconds);
    try jws.objectField("query_time_ns");
    try jws.write(run_result.query_time.nanoseconds);
    try jws.endObject();
    try jws.endObject();
}

fn finishErr(buf: *std.Io.Writer.Allocating, out: *Result, msg: []const u8) void {
    buf.clearRetainingCapacity();
    buf.writer.writeAll(msg) catch return fail(buf, out);
    const slice = buf.toOwnedSlice() catch return fail(buf, out);
    out.* = .{ .status = 1, .ptr = slice.ptr, .len = slice.len };
}

/// Report `err` with every diagnostic the compilation collected, one per
/// line. Falls back to the error's name when there are none.
fn finishDiagnostics(
    buf: *std.Io.Writer.Allocating,
    out: *Result,
    sink: *const tql.diagnostic.Sink,
    err: anyerror,
) void {
    if (sink.items().len == 0) return finishErr(buf, out, @errorName(err));
    buf.clearRetainingCapacity();
    for (sink.items(), 0..) |d, i| {
        if (i > 0) buf.writer.writeByte('\n') catch return fail(buf, out);
        buf.writer.print("{f}: {s}: {s}", .{ d.span, d.category.name(), d.message }) catch
            return fail(buf, out);
    }
    const slice = buf.toOwnedSlice() catch return fail(buf, out);
    out.* = .{ .status = 1, .ptr = slice.ptr, .len = slice.len };
}

fn fail(buf: *std.Io.Writer.Allocating, out: *Result) void {
    buf.deinit();
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

    if (language_ptr == 0) return finishErr(&buf, out, "null language pointer");
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);
    const grammar = tql.Grammar{
        .name = "dynamic",
        .extensions = &.{},
        .language = language,
    };

    var sink = tql.diagnostic.Sink.init(gpa);
    defer sink.deinit();

    runImpl(&grammar, query_ptr[0..query_len], target_ptr[0..target_len], &buf, &sink) catch |err| {
        return finishDiagnostics(&buf, out, &sink, err);
    };

    const slice = buf.toOwnedSlice() catch return fail(&buf, out);
    out.* = .{ .status = 0, .ptr = slice.ptr, .len = slice.len };
}

export fn tql_parse_tree(
    language_ptr: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);

    if (language_ptr == 0) return finishErr(&buf, out, "null language pointer");
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);

    parseTreeImpl(language, target_ptr[0..target_len], &buf) catch |err| {
        return finishErr(&buf, out, @errorName(err));
    };

    const slice = buf.toOwnedSlice() catch return fail(&buf, out);
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

    var rows: std.ArrayList(tql.inspect.Row) = .empty;
    defer rows.deinit(gpa);
    try tql.inspect.collect(gpa, &rows, tree.rootNode(), target, .{});

    var jws: std.json.Stringify = .{ .writer = &buf.writer };
    try tql.inspect.writeJson(rows.items, &jws);
}
