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

const Subcommands = enum {
    run,
    help,
};

const main_parsers = .{
    .command = clap.parsers.enumeration(Subcommands),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help                  Display this help and exit
    \\<command>
    \\
);

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,

        // Terminate the parsing of arguments after parsing the first positional (0 is passed
        // here because parsed positionals are, like slices and arrays, indexed starting at 0).
        //
        // This will terminate the parsing after parsing the subcommand enum and leave `iter`
        // not fully consumed. It can then be reused to parse the arguments for subcommands.
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(init.io, .stderr(), clap.Help, &main_params, .{
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
        return @intFromEnum(ExitCode.success);
    }

    const command = res.positionals[0] orelse return error.MissingCommand;
    switch (command) {
        .help => {
            try clap.helpToFile(init.io, .stderr(), clap.Help, &main_params, .{
                .description_on_new_line = false,
                .spacing_between_parameters = 0,
            });
            return @intFromEnum(ExitCode.success);
        },
        .run => {
            return runMain(init.io, init.gpa, stdout, stderr, &iter);
        },
    }
}

fn runMain(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    iter: *std.process.Args.Iterator,
) !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit
        \\-v, --version               Display version and exit
        \\-w, --workers <usize>       Number of workers
        \\-l, --language <language>   Language
        \\-f, --from-file <file>      Load the query from a file
        \\    --progress              Show progress
        \\<query>
        \\<file>...
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        // .format = clap.parsers.enumeration(OutputFormat),
        .language = clap.parsers.enumeration(Language),
        .usize = clap.parsers.int(usize, 10),
        .file = clap.parsers.string,
        .query = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return @intFromEnum(ExitCode.invalid_args);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &params, .{
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
        const file = try std.Io.Dir.cwd().openFile(io, query_file, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        const contents = try file_reader.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
        break :blk contents;
    } else blk: {
        const buf = try gpa.dupe(u8, query_or_first_file);
        break :blk buf;
    };
    defer gpa.free(query);

    // IMPROVE: read stdin if files.len = 0
    const files = if (res.args.@"from-file") |_| blk: {
        const buf = try gpa.alloc([]const u8, res.positionals[1].len + 1);
        buf[0] = query_or_first_file;
        @memcpy(buf[1 .. res.positionals[1].len + 1], res.positionals[1]);
        break :blk buf;
    } else blk: {
        const buf = try gpa.alloc([]const u8, res.positionals[1].len);
        @memcpy(buf, res.positionals[1]);
        break :blk buf;
    };
    defer gpa.free(files);

    const language = res.args.language orelse {
        try stderr.print("Error: --language is required\n", .{});
        try printUsage(stderr);
        return @intFromEnum(ExitCode.invalid_args);
    };

    return run(gpa, io, stdout, stderr, .{
        .query = query,
        .query_target_paths = files,
        .format = .json,
        .language = language,
        .workers = res.args.workers orelse 1,
        .stats = false,
        .verbose = false,
        .progress = res.args.progress != 0,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.runtime_error);
    };
}

fn runGrammar(
    _: std.Io,
    _: std.mem.Allocator,
    _: *std.Io.Writer,
    _: *std.Io.Writer,
    _: *std.process.Args.Iterator,
) !u8 {
    return @intFromEnum(ExitCode.success);
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

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}

const BAR_WIDTH: usize = 30;

fn renderProgress(w: *std.Io.Writer, done: usize, total: usize, done_walk: bool) void {
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

fn progressThread(io: std.Io, p: *Progress, stop: *std.atomic.Value(bool), w: *std.Io.Writer) !void {
    while (!stop.load(.acquire)) {
        renderProgress(w, p.done.load(.monotonic), p.total.load(.monotonic), p.*.done_walk);
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .real);
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
    read_time: std.Io.Duration = .zero,
    parse_time: std.Io.Duration = .zero,
    query_time: std.Io.Duration = .zero,
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
    compiled: *tql.Query,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    result_queue: *ResultQueue,
    path_queue: *PathQueue,
    language: Language,
    progress: *Progress,
    io: std.Io,
};

fn pushFile(ctx: *SharedContext, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, path);
    try ctx.path_queue.push(.{ .arena = arena, .path = owned });
    _ = ctx.*.progress.total.fetchAdd(1, .monotonic);
}

fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    const abs = try std.Io.Dir.realPathFileAbsoluteAlloc(ctx.*.io, path, ctx.allocator);
    defer ctx.allocator.free(abs);
    var root_dir = try std.Io.Dir.openDirAbsolute(ctx.*.io, abs, .{
        .iterate = true,
    });

    var walker = try root_dir.walk(ctx.*.allocator);
    while (try walker.next(ctx.*.io)) |entry| {
        if (entry.kind == .file and ctx.*.language.matchesFileName(entry.basename)) {
            const joined = try std.fs.path.join(
                ctx.*.allocator,
                &[_][]const u8{ path, entry.path },
            );
            defer ctx.*.allocator.free(joined);
            try pushFile(ctx, joined);
        }
    }
    walker.deinit();
    root_dir.close(ctx.io);
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
    try ctx.path_queue.close();
}

fn writerThread(ctx: *SharedContext, jws: *std.json.Stringify) !void {
    var totals: FileStats = .{};
    try jws.beginObject();
    try jws.objectField("results");
    try jws.beginArray();
    while (try ctx.result_queue.pop()) |result| {
        defer result.deinit();
        totals.read_time = std.Io.Duration.fromNanoseconds(totals.read_time.nanoseconds + result.stats.read_time.nanoseconds);
        totals.parse_time = std.Io.Duration.fromNanoseconds(totals.parse_time.nanoseconds + result.stats.parse_time.nanoseconds);
        totals.query_time = std.Io.Duration.fromNanoseconds(totals.query_time.nanoseconds + result.stats.query_time.nanoseconds);
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
    try jws.write(totals.read_time.nanoseconds);
    try jws.objectField("parse_time_ns");
    try jws.write(totals.parse_time.nanoseconds);
    try jws.objectField("query_time_ns");
    try jws.write(totals.query_time.nanoseconds);
    try jws.endObject();
    try jws.endObject();
}

fn workerThread(ctx: *SharedContext) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    defer arena.deinit();

    while (try ctx.path_queue.pop()) |entry| {
        var result_arena = entry.arena;
        errdefer result_arena.deinit();
        const result_alloc = result_arena.allocator();
        const query_target_path = entry.path;

        const read_start = std.Io.Timestamp.now(ctx.io, .real);
        const query_target: []align(std.heap.page_size_min) const u8 = blk: {
            const file = try std.Io.Dir.cwd().openFile(ctx.io, query_target_path, .{});
            defer file.close(ctx.io);
            const stat = try file.stat(ctx.io);
            if (stat.size == 0) break :blk &[_]u8{};
            break :blk try std.posix.mmap(
                null,
                stat.size,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
        };
        const read_time = read_start.untilNow(ctx.io, .real);
        defer if (query_target.len > 0) std.posix.munmap(query_target);

        const run_result = try ctx.compiled.run(query_target, result_alloc, arena.allocator());

        try ctx.result_queue.push(.{
            .arena = result_arena,
            .filename = query_target_path,
            .values = run_result.values,
            .stats = .{
                .read_time = read_time,
                .parse_time = run_result.stats.parse_time,
                .query_time = run_result.stats.query_time,
            },
        });

        _ = arena.reset(.retain_capacity);
        _ = ctx.*.progress.done.fetchAdd(1, .monotonic);
    }
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    config: Config,
) !u8 {
    var engine = try Engine.init(.{
        .allocator = allocator,
        .io = io,
    });
    defer engine.deinit();

    var compiled = try engine.compile(config.query, config.language);
    defer compiled.deinit();

    // real shit
    var jws: std.json.Stringify = .{ .writer = stdout };
    var path_queue = try PathQueue.init(allocator, io, 65535);
    var result_queue = try ResultQueue.init(allocator, io, 1024);
    var progress = Progress{};
    var ctx = SharedContext{
        .compiled = &compiled,
        .paths = config.query_target_paths,
        .allocator = allocator,
        .result_queue = &result_queue,
        .path_queue = &path_queue,
        .language = config.language,
        .progress = &progress,
        .io = io,
    };

    var progress_stop = std.atomic.Value(bool).init(false);
    var walker_thread = try std.Thread.spawn(.{}, walkerThread, .{&ctx});
    const writer_thread = try std.Thread.spawn(.{}, writerThread, .{ &ctx, &jws });
    const progress_thread = if (config.progress) try std.Thread.spawn(.{}, progressThread, .{ io, &progress, &progress_stop, stderr }) else null;
    var workers = try allocator.alloc(std.Thread, config.workers);

    for (0..config.workers) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{&ctx});
    }

    for (workers) |*worker| {
        worker.join();
    }
    try ctx.result_queue.close();

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
