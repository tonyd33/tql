const std = @import("std");
const tql = @import("tql_engine_zig");
const clap = @import("clap");
const Engine = tql.Engine;
const Language = tql.Language;
const Value = tql.Value;

const VERSION = tql.VERSION;

const OutputFormat = enum {
    // IMPROVE: actually implement these
    text,
    json,
    locations,
};

const ExitCode = enum(u8) {
    success = 0,
    no_matches = 1,
    parse_error = 2,
    compilation_error = 3,
    runtime_error = 4,
    invalid_args = 5,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa.deinit();
        if (result == .leak) @panic("memory leaked");
    }
    const allocator = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit
        \\-v, --version               Display version and exit
        \\-w, --workers <usize>       Number of workers
        \\-l, --language <language>   Language
        \\-f, --from-file <file>      Load the query from a file
        \\    --format <format>       Output format (text, json, locations)
        \\    --progress              Show progress
        \\    --stats                 Print runtime statistics
        \\    --verbose               Verbose output
        \\<query>
        \\<file>...
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .format = clap.parsers.enumeration(OutputFormat),
        .language = clap.parsers.enumeration(Language),
        .usize = clap.parsers.int(usize, 10),
        .file = clap.parsers.string,
        .query = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        try stderr.flush();
        return @intFromEnum(ExitCode.invalid_args);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
        return @intFromEnum(ExitCode.success);
    }

    if (res.args.version != 0) {
        try printVersion(stdout);
        return @intFromEnum(ExitCode.success);
    }
    // If --from-file, then this will be the query file.
    // Otherwise, this is the first target file.
    const query_or_first_file = res.positionals[0] orelse {
        try stderr.print("Error: query is required\n", .{});
        try printUsage(stderr);
        return @intFromEnum(ExitCode.invalid_args);
    };

    const query = if (res.args.@"from-file") |query_file| blk: {
        const file = try std.fs.cwd().openFile(query_file, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    } else blk: {
        const buf = try allocator.dupe(u8, query_or_first_file);
        break :blk buf;
    };
    defer allocator.free(query);

    // IMPROVE: read stdin if files.len = 0
    const files = if (res.args.@"from-file") |_| blk: {
        const buf = try allocator.alloc([]const u8, res.positionals[1].len + 1);
        buf[0] = query_or_first_file;
        @memcpy(buf[1 .. res.positionals[1].len + 1], res.positionals[1]);
        break :blk buf;
    } else blk: {
        const buf = try allocator.alloc([]const u8, res.positionals[1].len);
        @memcpy(buf, res.positionals[1]);
        break :blk buf;
    };
    defer allocator.free(files);

    const language = res.args.language orelse {
        try stderr.print("Error: --language is required\n", .{});
        try printUsage(stderr);
        return @intFromEnum(ExitCode.invalid_args);
    };

    return run(allocator, stdout, stderr, .{
        .query = query,
        .query_target_paths = files,
        .format = res.args.format orelse .json,
        .language = language,
        .workers = res.args.workers orelse 1,
        .stats = res.args.stats != 0,
        .verbose = res.args.verbose != 0,
        .progress = res.args.progress != 0,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.runtime_error);
    };
}

const Config = struct {
    query: []const u8,
    query_target_paths: []const []const u8,
    format: OutputFormat,
    language: Language,
    workers: usize = 1,
    stats: bool,
    verbose: bool,
    progress: bool,
};

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}

const BAR_WIDTH: usize = 30;

fn renderProgress(w: *std.io.Writer, done: usize, total: usize, done_walk: bool) void {
    _ = done_walk;
    // const pct: usize = if (t == 0) 0 else (d * 100) / t;
    const filled: usize = if (total == 0) 0 else (done * BAR_WIDTH) / total;
    var buf: [BAR_WIDTH * 3]u8 = undefined;
    var i: usize = 0;
    var k: usize = 0;
    while (k < BAR_WIDTH) : (k += 1) {
        const glyph = if (k < filled) "#" else "-";
        @memcpy(buf[i .. i + glyph.len], glyph);
        i += glyph.len;
    }
    w.print("\r[{s}] {d}/{d}", .{ buf[0..i], done, total }) catch {};
    w.flush() catch {};
}

fn progressThread(p: *Progress, stop: *std.atomic.Value(bool), w: *std.io.Writer) void {
    while (!stop.load(.acquire)) {
        renderProgress(w, p.done.load(.monotonic), p.total.load(.monotonic), p.*.done_walk);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    renderProgress(w, p.done.load(.monotonic), p.total.load(.monotonic), p.*.done_walk);
    w.print("\n", .{}) catch {};
    w.flush() catch {};
}

// IMPROVE: almost much everything below belongs in the lib. We're trying to
// "feel out" an appropriate engine API from CLI usage.

const PathEntry = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
};

const PathQueue = tql.ds.BlockingQueue(PathEntry);

const FileStats = struct {
    read_time_ns: u64 = 0,
    parse_time_ns: u64 = 0,
    query_time_ns: u64 = 0,
};

const FileResult = struct {
    arena: std.heap.ArenaAllocator,
    filename: []const u8,
    values: std.ArrayList(Value),
    stats: FileStats,

    fn deinit(self: FileResult) void {
        self.arena.deinit();
    }
};

const ResultQueue = tql.ds.BlockingQueue(FileResult);

const Progress = struct {
    done: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    done_walk: bool = false,
};

const SharedContext = struct {
    compiled: *tql.CompiledQuery,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    result_queue: *ResultQueue,
    path_queue: *PathQueue,
    language: Language,
    progress: *Progress,
};

fn pushFile(ctx: *SharedContext, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, path);
    try ctx.path_queue.push(.{ .arena = arena, .path = owned });
    _ = ctx.*.progress.total.fetchAdd(1, .monotonic);
}

fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try std.fs.realpath(path, &buf);
    var root_dir = try std.fs.openDirAbsolute(abs, .{
        .iterate = true,
    });

    var walker = try root_dir.walk(ctx.*.allocator);
    while (try walker.next()) |entry| {
        if (entry.kind == .file and (std.mem.endsWith(u8, entry.basename, ".c") or std.mem.endsWith(u8, entry.basename, ".h"))) {
            const joined = try std.fs.path.join(
                ctx.*.allocator,
                &[_][]const u8{ path, entry.path },
            );
            defer ctx.*.allocator.free(joined);
            try pushFile(ctx, joined);
        }
    }
    walker.deinit();
    root_dir.close();
    ctx.*.progress.*.done_walk = true;
}

fn walkerThread(ctx: *SharedContext) !void {
    for (ctx.*.paths) |path| {
        walkPush(ctx, path) catch |err| {
            if (err == error.NotDir) {
                try pushFile(ctx, path);
            } else {
                return err;
            }
        };
    }
    ctx.path_queue.close();
}

fn writerThread(ctx: *SharedContext, jws: *std.json.Stringify) !void {
    var totals: FileStats = .{};
    try jws.beginObject();
    try jws.objectField("results");
    try jws.beginArray();
    while (ctx.result_queue.pop()) |result| {
        defer result.deinit();
        totals.read_time_ns += result.stats.read_time_ns;
        totals.parse_time_ns += result.stats.parse_time_ns;
        totals.query_time_ns += result.stats.query_time_ns;
        if (result.values.items.len == 0) continue;
        try jws.beginObject();
        try jws.objectField("file");
        try jws.write(result.filename);
        try jws.objectField("values");
        try jws.beginArray();
        for (result.values.items) |v| try v.jsonStringify(jws);
        try jws.endArray();
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("stats");
    try jws.beginObject();
    try jws.objectField("read_time_ns");
    try jws.write(totals.read_time_ns);
    try jws.objectField("parse_time_ns");
    try jws.write(totals.parse_time_ns);
    try jws.objectField("query_time_ns");
    try jws.write(totals.query_time_ns);
    try jws.endObject();
    try jws.endObject();
}

fn workerThread(ctx: *SharedContext) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    defer arena.deinit();

    while (ctx.path_queue.pop()) |entry| {
        var result_arena = entry.arena;
        errdefer result_arena.deinit();
        const result_alloc = result_arena.allocator();
        const query_target_path = entry.path;

        var read_timer = try std.time.Timer.start();
        const query_target: []align(std.heap.page_size_min) const u8 = blk: {
            const file = try std.fs.cwd().openFile(query_target_path, .{});
            defer file.close();
            const stat = try file.stat();
            if (stat.size == 0) break :blk &[_]u8{};
            break :blk try std.posix.mmap(
                null,
                stat.size,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
        };
        const read_time_ns = read_timer.read();
        defer if (query_target.len > 0) std.posix.munmap(query_target);

        const run_result = try ctx.compiled.run(query_target, result_alloc, arena.allocator());

        try ctx.result_queue.push(.{
            .arena = result_arena,
            .filename = query_target_path,
            .values = run_result.values,
            .stats = .{
                .read_time_ns = read_time_ns,
                .parse_time_ns = run_result.stats.parse_time_ns,
                .query_time_ns = run_result.stats.query_time_ns,
            },
        });

        _ = arena.reset(.retain_capacity);
        _ = ctx.*.progress.done.fetchAdd(1, .monotonic);
    }
}

fn run(
    allocator: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    config: Config,
) !u8 {
    var engine = try Engine.init(.{ .allocator = allocator });
    defer engine.deinit();

    var compiled = try engine.compile(config.query, config.language);
    defer compiled.deinit();

    // real shit
    var jws: std.json.Stringify = .{ .writer = stdout };
    var path_queue = try PathQueue.init(allocator, 65535);
    var result_queue = try ResultQueue.init(allocator, 1024);
    var progress = Progress{};
    var ctx = SharedContext{
        .compiled = &compiled,
        .paths = config.query_target_paths,
        .allocator = allocator,
        .result_queue = &result_queue,
        .path_queue = &path_queue,
        .language = config.language,
        .progress = &progress,
    };

    var progress_stop = std.atomic.Value(bool).init(false);
    var walker_thread = try std.Thread.spawn(.{}, walkerThread, .{&ctx});
    const writer_thread = try std.Thread.spawn(.{}, writerThread, .{ &ctx, &jws });
    const progress_thread = if (config.progress) try std.Thread.spawn(.{}, progressThread, .{ &progress, &progress_stop, stderr }) else null;
    var workers = try allocator.alloc(std.Thread, config.workers);

    for (0..config.workers) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{&ctx});
    }

    for (workers) |*worker| {
        worker.join();
    }
    ctx.result_queue.close();

    walker_thread.join();
    progress_stop.store(true, .release);
    if (progress_thread) |p| {
        p.join();
    }
    writer_thread.join();

    path_queue.deinit(allocator);
    result_queue.deinit(allocator);
    allocator.free(workers);
    return 0;
}
