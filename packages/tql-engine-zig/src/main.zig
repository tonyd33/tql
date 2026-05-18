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

    var stdout_buffer: [4096]u8 = undefined;
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
        .format = res.args.format orelse .text,
        .workers = res.args.workers,
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
    workers: ?usize,
    captures: bool,
    dump_ast: bool,
    dump_instructions: bool,
    stats: bool,
    verbose: bool,
};

// IMPROVE: need better queue
const PathQueue = tql.ds.ThreadSafe(tql.ds.RingBuffer([]const u8));
const ResultQueue = tql.ds.ThreadSafe(std.json.Stringify);

const SharedContext = struct {
    program_image: tql.Runtime.ProgramImage,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    writer: *ResultQueue,
    path_queue: *PathQueue,
    language: Language,
};

fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    var root_dir = try std.fs.openDirAbsolute(path, .{
        .iterate = true,
    });

    var walker = try root_dir.walk(ctx.*.allocator);
    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".c")) {
            const cp = try std.fs.path.join(
                ctx.*.allocator,
                &[_][]const u8{ path, entry.path },
            );
            var guard = ctx.*.path_queue.*.lock();
            try guard.inner.*.push(cp);
            guard.release();
        }
    }
    walker.deinit();
    root_dir.close();
}

fn walkerThread(ctx: *SharedContext) !void {
    // FIXME: need to apply backpressure for fixed size queue buffer
    // FIXME: awful control flow
    for (ctx.*.paths) |path| {
        walkPush(ctx, path) catch |err| {
            if (err == error.NotDir) {
                const cp = try ctx.*.allocator.dupe(u8, path);
                var guard = ctx.*.path_queue.*.lock();
                try guard.inner.*.push(cp);
                guard.release();
            } else {
                return err;
            }
        };
    }
}

fn workerThread(ctx: *SharedContext) !void {
    // TODO: need to store results per file and flush to the writer
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    const arena_allocator = arena.allocator();
    const source_parser = ts.Parser.create();
    try source_parser.setLanguage(ctx.*.language.getTreeSitterLanguage());

    while (blk: {
        const guard = ctx.*.path_queue.*.lock();
        const result = guard.inner.*.pop();
        guard.release();
        break :blk result;
    }) |*query_target_path| {
        std.debug.print("{s}\n", .{query_target_path.*});
        const query_target = blk: {
            const file = try std.fs.cwd().openFile(query_target_path.*, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(arena_allocator, 10 * 1024 * 1024);
        };
        ctx.allocator.free(query_target_path.*);

        const tree_target = source_parser.parseString(query_target, null) orelse return error.SourceParseFailed;
        std.debug.print("finished parsing\n", .{});

        var query = tql.Query.init(
            &ctx.program_image,
            ctx.*.language,
            query_target,
            tree_target,
            arena_allocator,
        );
        try query.exec();

        while (try query.next()) |value| {
            var v = value;

            const guard = ctx.*.writer.*.lock();
            try v.jsonStringify(guard.inner);
            guard.release();

            v.deinit(arena_allocator);
        }

        query.deinit();
        tree_target.destroy();
        _ = arena.reset(.retain_capacity);
    }

    source_parser.destroy();
    arena.deinit();
}

fn run(
    allocator: std.mem.Allocator,
    stdout: *std.io.Writer,
    _: *std.io.Writer,
    config: Config,
) !u8 {
    // FIXME: We shouldn't need this
    const language = Language.c;

    var tql_parser = try tql.Parser.init(allocator);

    var compiler = tql.Compiler.init(allocator, language.getTreeSitterLanguage());

    const query_source = blk: {
        const file = try std.fs.cwd().openFile(config.query_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };

    // real shit
    const query_source_tree = try tql_parser.parse(query_source);
    allocator.free(query_source);
    tql_parser.deinit();

    var program_image = try compiler.compile(allocator, query_source_tree);
    compiler.deinit();
    query_source_tree.deinit(allocator);

    var jws = ResultQueue{ .inner = .{ .writer = stdout } };
    var path_queue_inner = try tql.ds.RingBuffer([]const u8).init(allocator, 65535);
    var path_queue = PathQueue{ .inner = path_queue_inner };
    var ctx = SharedContext{
        .program_image = program_image,
        .paths = config.query_target_paths,
        .allocator = allocator,
        .writer = &jws,
        .path_queue = &path_queue,
        .language = language,
    };
    const num_workers = 1;
    // TODO: actual thread
    try walkerThread(&ctx);
    var workers: [num_workers]std.Thread = undefined;

    // TODO: writer thread
    try jws.inner.beginArray();
    for (0..num_workers) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerThread, .{&ctx});
    }

    for (&workers) |*worker| {
        worker.join();
    }

    try jws.inner.endArray();

    path_queue_inner.deinit(allocator);
    program_image.deinit();
    return 0;
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}
