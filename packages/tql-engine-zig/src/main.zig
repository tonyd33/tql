const std = @import("std");
const tql = @import("tql_engine_zig");
const ts = tql.ts;
const clap = @import("clap");
const Engine = tql.Engine;
const Language = tql.Language;
const Value = tql.Value;

const VERSION = "0.1.0";

const OutputFormat = enum {
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
        \\-h, --help                  Display this help and exit.
        \\-v, --version               Display version and exit.
        \\-f, --format <format>       Output format (text, json, locations).
        \\-w, --workers <usize>       Number of workers
        \\    --captures              Include variable captures/bindings.
        \\    --dump-ast              Print parsed query AST and exit.
        \\    --dump-instructions     Print compiled bytecode and exit.
        \\    --stats                 Print runtime statistics.
        \\    --verbose               Verbose output.
        \\<file>...
        \\
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .format = clap.parsers.enumeration(OutputFormat),
        .usize = clap.parsers.int(usize, 10),
        .file = clap.parsers.string,
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

    const files = res.positionals[0];
    if (files.len < 2) {
        try stderr.print("Error: Expected at least 2 arguments (query file and source file)\n", .{});
        try printUsage(stderr);
        return @intFromEnum(ExitCode.invalid_args);
    }

    const query_path = files[0];
    const source_paths = files[1..];

    return run(allocator, stdout, stderr, .{
        .query_path = query_path,
        .query_target_paths = source_paths,
        .format = res.args.format orelse .json,
        .workers = res.args.workers orelse 1,
        .captures = res.args.captures != 0,
        .dump_ast = res.args.@"dump-ast" != 0,
        .dump_instructions = res.args.@"dump-instructions" != 0,
        .stats = res.args.stats != 0,
        .verbose = res.args.verbose != 0,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.runtime_error);
    };
}

const Config = struct {
    query_path: []const u8,
    query_target_paths: []const []const u8,
    format: OutputFormat,
    workers: usize = 1,
    captures: bool,
    dump_ast: bool,
    dump_instructions: bool,
    stats: bool,
    verbose: bool,
};

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
};

const SharedContext = struct {
    program_image: tql.Runtime.ProgramImage,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    result_queue: *ResultQueue,
    path_queue: *PathQueue,
    language: Language,
    progress: *Progress,
};

const BAR_WIDTH: usize = 30;

fn renderProgress(w: *std.io.Writer, d: usize, t: usize) void {
    // const pct: usize = if (t == 0) 0 else (d * 100) / t;
    const filled: usize = if (t == 0) 0 else (d * BAR_WIDTH) / t;
    var buf: [BAR_WIDTH * 3]u8 = undefined;
    var i: usize = 0;
    var k: usize = 0;
    while (k < BAR_WIDTH) : (k += 1) {
        const glyph = if (k < filled) "#" else "-";
        @memcpy(buf[i .. i + glyph.len], glyph);
        i += glyph.len;
    }
    w.print("\r[{s}] {d}/{d}", .{ buf[0..i], d, t }) catch {};
    w.flush() catch {};
}

fn progressThread(p: *Progress, stop: *std.atomic.Value(bool), w: *std.io.Writer) void {
    while (!stop.load(.acquire)) {
        renderProgress(w, p.done.load(.monotonic), p.total.load(.monotonic));
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    renderProgress(w, p.done.load(.monotonic), p.total.load(.monotonic));
    w.print("\n", .{}) catch {};
    w.flush() catch {};
}

fn pushFile(ctx: *SharedContext, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, path);
    try ctx.path_queue.push(.{ .arena = arena, .path = owned });
    _ = ctx.*.progress.total.fetchAdd(1, .monotonic);
}

fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    var root_dir = try std.fs.openDirAbsolute(path, .{
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
    const arena_allocator = arena.allocator();
    const source_parser = ts.Parser.create();
    try source_parser.setLanguage(ctx.*.language.getTreeSitterLanguage());

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

        var parse_timer = try std.time.Timer.start();
        const tree_target = source_parser.parseString(query_target, null) orelse return error.SourceParseFailed;
        const parse_time_ns = parse_timer.read();

        var query = tql.Query.init(
            &ctx.program_image,
            ctx.*.language,
            query_target,
            tree_target,
            arena_allocator,
        );
        try query.exec();

        var values: std.ArrayList(Value) = .empty;
        var query_timer = try std.time.Timer.start();
        while (try query.next(result_alloc)) |value| {
            try values.append(result_alloc, value);
        }
        const query_time_ns = query_timer.read();

        try ctx.result_queue.push(.{
            .arena = result_arena,
            .filename = query_target_path,
            .values = values,
            .stats = .{
                .read_time_ns = read_time_ns,
                .parse_time_ns = parse_time_ns,
                .query_time_ns = query_time_ns,
            },
        });

        query.deinit();
        tree_target.destroy();
        _ = arena.reset(.retain_capacity);
        _ = ctx.*.progress.done.fetchAdd(1, .monotonic);
    }

    source_parser.destroy();
    arena.deinit();
}

fn dumpInstructions(
    _: std.mem.Allocator,
    stdout: *std.io.Writer,
    _: *std.io.Writer,
    _: Config,
    instructions: []const tql.Runtime.Instruction,
) !void {
    for (instructions, 0..) |inst, i| {
        try stdout.print("{d:0>4}: ", .{i});
        try inst.print(stdout);
        try stdout.writeByte('\n');
    }
}

fn programImageFromQueryPath(allocator: std.mem.Allocator, query_path: []const u8) !tql.Runtime.ProgramImage {
    // FIXME: We shouldn't need this
    const language = Language.c;
    var tql_parser = try tql.Parser.init(allocator);

    var compiler = tql.Compiler.init(allocator, language.getTreeSitterLanguage());

    const query_source = blk: {
        const file = try std.fs.cwd().openFile(query_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };

    const query_source_tree = try tql_parser.parse(query_source);
    allocator.free(query_source);
    tql_parser.deinit();

    const program_image = try compiler.compile(allocator, query_source_tree);
    compiler.deinit();
    query_source_tree.deinit(allocator);

    return program_image;
}

fn run(
    allocator: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    config: Config,
) !u8 {
    // FIXME: We shouldn't need this
    const language = Language.c;
    var program_image = try programImageFromQueryPath(allocator, config.query_path);
    // IMPROVE: this control flow is terrible
    if (config.dump_instructions) {
        try dumpInstructions(allocator, stdout, stderr, config, program_image.instructions);
        program_image.deinit();
        return 0;
    }

    // real shit
    var jws: std.json.Stringify = .{ .writer = stdout };
    var path_queue = try PathQueue.init(allocator, 65535);
    var result_queue = try ResultQueue.init(allocator, 1024);
    var progress = Progress{};
    var ctx = SharedContext{
        .program_image = program_image,
        .paths = config.query_target_paths,
        .allocator = allocator,
        .result_queue = &result_queue,
        .path_queue = &path_queue,
        .language = language,
        .progress = &progress,
    };

    var progress_stop = std.atomic.Value(bool).init(false);
    var walker_thread = try std.Thread.spawn(.{}, walkerThread, .{&ctx});
    const writer_thread = try std.Thread.spawn(.{}, writerThread, .{ &ctx, &jws });
    const progress_thread = try std.Thread.spawn(.{}, progressThread, .{ &progress, &progress_stop, stderr });
    var workers = try allocator.alloc(std.Thread, config.workers);

    for (0..config.workers) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{&ctx});
    }

    for (workers) |*worker| {
        worker.join();
    }
    ctx.result_queue.close();

    walker_thread.join();
    writer_thread.join();
    progress_stop.store(true, .release);
    progress_thread.join();

    path_queue.deinit(allocator);
    result_queue.deinit(allocator);
    program_image.deinit();
    allocator.free(workers);
    return 0;
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}
