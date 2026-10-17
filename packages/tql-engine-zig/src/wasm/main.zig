const std = @import("std");
const tql = @import("tql");

const gpa = std.heap.wasm_allocator;

pub fn main() void {}

/// What a call wrote. Status 0 is a JSON reply `{"kind": ..}`: "ok" with
/// the call's value, "rejected" with the query's diagnostics, or "failed"
/// with a failure. Status 1 is no reply, for want of memory to write one.
const Result = extern struct {
    status: i32,
    ptr: [*]u8,
    len: usize,
};

/// Every zero-length buffer, at an address the caller can read from.
var empty: [1]u8 = undefined;

/// Returns a buffer of `len` bytes. A zero-length one is `empty`.
export fn tql_alloc(len: usize) ?[*]u8 {
    if (len == 0) return &empty;
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Frees a buffer of `len` bytes. A zero-length one needs no freeing.
export fn tql_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    gpa.free(ptr[0..len]);
}

/// Compiled by the first run and kept for every later one.
var shared_library: ?tql.Library = null;

fn writeRun(w: *std.Io.Writer, compiled: *const tql.CompiledQuery, run: tql.RunOutcome) !void {
    var jws: std.json.Stringify = .{ .writer = w };
    try jws.beginObject();
    try jws.objectField("kind");
    try jws.write("ok");
    try jws.objectField("result");
    try jws.beginObject();
    try jws.objectField("values");
    try jws.beginWriteRaw();
    try jws.writer.writeAll(run.json);
    jws.endWriteRaw();
    try jws.objectField("syntax_errors");
    try jws.write(run.syntax_errors);
    try jws.objectField("stats");
    try jws.write(.{
        .compile = compiled.times,
        .parse_time_ns = run.parse_time.nanoseconds,
        .query_time_ns = run.query_time.nanoseconds,
    });
    try jws.endObject();
    try jws.endObject();
}

fn writeRejected(w: *std.Io.Writer, engine: *const tql.Engine, sink: *const tql.diagnostic.Sink) !void {
    var jws: std.json.Stringify = .{ .writer = w };
    try jws.beginObject();
    try jws.objectField("kind");
    try jws.write("rejected");
    try jws.objectField("diagnostics");
    try jws.beginArray();
    for (sink.items()) |d| try jws.write(.{
        .category = d.category.name(),
        .message = d.message,
        .module = engine.sourceOf(d.span.source, .{ .name = null, .text = "" }).name,
        .span = if (d.span.isUnknown()) null else d.span,
    });
    try jws.endArray();
    try jws.endObject();
}

fn reply(buf: *std.Io.Writer.Allocating, out: *Result) void {
    const slice = buf.toOwnedSlice() catch return fail(buf, out);
    out.* = .{ .status = 0, .ptr = slice.ptr, .len = slice.len };
}

fn fail(buf: *std.Io.Writer.Allocating, out: *Result) void {
    buf.deinit();
    out.* = .{ .status = 1, .ptr = undefined, .len = 0 };
}

fn finishFailure(buf: *std.Io.Writer.Allocating, out: *Result, failure: tql.Failure) void {
    buf.clearRetainingCapacity();
    var jws: std.json.Stringify = .{ .writer = &buf.writer };
    jws.write(.{ .kind = "failed", .failure = failure }) catch return fail(buf, out);
    reply(buf, out);
}

/// Serves the modules a caller passed as one JSON object of name to source.
const JsonModules = struct {
    map: std.json.ArrayHashMap([]const u8),

    fn loader(self: *JsonModules) tql.Loader {
        return .{ .context = self, .loadFn = load };
    }

    fn load(context: *anyopaque, name: []const u8) tql.load.Loaded {
        const self: *JsonModules = @ptrCast(@alignCast(context));
        const text = self.map.map.get(name) orelse return .missing;
        return .{ .found = .{ .name = name, .text = text } };
    }
};

/// Runs a query against a target under the grammar at `language_ptr`, named
/// `grammar_name` for `for` clauses. `modules` is a JSON object mapping each
/// importable module's name to its source.
export fn tql_run_dynamic(
    language_ptr: usize,
    grammar_name_ptr: [*]const u8,
    grammar_name_len: usize,
    query_ptr: [*]const u8,
    query_len: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    modules_ptr: [*]const u8,
    modules_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);

    if (language_ptr == 0) return finishFailure(&buf, out, .{ .internal = error.NullLanguagePointer });
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);
    const grammar = tql.Grammar{
        .name = grammar_name_ptr[0..grammar_name_len],
        .extensions = &.{},
        .language = language,
    };

    const modules = std.json.parseFromSlice(
        std.json.ArrayHashMap([]const u8),
        gpa,
        modules_ptr[0..modules_len],
        .{},
    ) catch |err| return finishFailure(&buf, out, .{ .internal = err });
    defer modules.deinit();
    var served: JsonModules = .{ .map = modules.value };

    var single_threaded = std.Io.Threaded.init_single_threaded;
    var engine = tql.Engine.init(.{
        .allocator = gpa,
        .io = single_threaded.io(),
    }) catch |err| return finishFailure(&buf, out, .ofAny(err));
    defer engine.deinit();
    engine.loader = served.loader();

    var sink = tql.diagnostic.Sink.init(gpa);
    defer sink.deinit();

    if (shared_library == null) {
        shared_library = tql.Library.init(gpa, &sink) catch |err| return finishFailure(&buf, out, .ofAny(err));
    }
    engine.library = &shared_library.?;

    var compiled = engine.compileQuery(query_ptr[0..query_len], &grammar, &sink) catch |err| {
        if (sink.items().len == 0) return finishFailure(&buf, out, .ofAny(err));
        writeRejected(&buf.writer, &engine, &sink) catch return fail(&buf, out);
        return reply(&buf, out);
    };
    defer compiled.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const run = compiled.run(target_ptr[0..target_len], null, arena.allocator(), arena.allocator()) catch |err|
        return finishFailure(&buf, out, .ofRun(err));
    writeRun(&buf.writer, &compiled, run) catch return fail(&buf, out);
    reply(&buf, out);
}

export fn tql_parse_tree(
    language_ptr: usize,
    target_ptr: [*]const u8,
    target_len: usize,
    out: *Result,
) void {
    var buf = std.Io.Writer.Allocating.init(gpa);

    if (language_ptr == 0) return finishFailure(&buf, out, .{ .internal = error.NullLanguagePointer });
    const language: *const tql.ts.Language = @ptrFromInt(language_ptr);

    const parser = tql.ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language) catch return finishFailure(&buf, out, .incompatible_grammar);
    const target = target_ptr[0..target_len];
    const tree = parser.parseString(target, null) orelse return finishFailure(&buf, out, .target_parse_failed);
    defer tree.destroy();

    writeTree(&buf.writer, tree.rootNode(), target) catch return fail(&buf, out);
    reply(&buf, out);
}

fn writeTree(w: *std.Io.Writer, root: tql.ts.Node, target: []const u8) !void {
    var rows: std.ArrayList(tql.inspect.Row) = .empty;
    defer rows.deinit(gpa);
    try tql.inspect.collect(gpa, &rows, root, target, .{});

    var jws: std.json.Stringify = .{ .writer = w };
    try jws.beginObject();
    try jws.objectField("kind");
    try jws.write("ok");
    try jws.objectField("rows");
    try tql.inspect.writeJson(rows.items, &jws);
    try jws.endObject();
}
