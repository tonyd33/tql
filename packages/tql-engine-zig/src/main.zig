const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const Engine = tql.Engine;
const Grammar = tql.Grammar;
const Value = tql.Value;

const VERSION = tql.VERSION;

const ArgTokenizer = goz.ArgTokenizer;
const SubcmdResolver = goz.SubcmdResolver;
const Opt = goz.Opt;
const Positional = goz.Positional;
const printUsage = goz.printUsage;

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

const main_opts = .{
    .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
};

const main_cmds = .{
    .query = .{
        .aliases = &[_][]const u8{"run"},
        .description = @as(?[]const u8, "Run a query against files"),
        .opts = .{
            .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
            .from_file = Opt{ .names = .{ .long = "from-file", .short = 'f' }, .has_arg = .required_argument, .meta = "file", .description = "Load query from file" },
            .workers = Opt{ .names = .{ .long = "workers", .short = 'w' }, .has_arg = .required_argument, .meta = "n", .description = "Number of workers (default: 1)" },
            .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar" },
            .progress = Opt{ .names = .{ .long = "progress" }, .description = "Show progress" },
        },
    },
    .version = .{
        .aliases = &[_][]const u8{},
        .description = @as(?[]const u8, "Get version info"),
        .opts = .{},
    },
    .grammar = .{
        .aliases = &[_][]const u8{},
        .description = @as(?[]const u8, "Manage grammars"),
        .opts = .{
            .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
            .install_dir = Opt{ .names = .{ .long = "install-dir" }, .has_arg = .required_argument, .meta = "dir", .description = "Grammar install directory" },
        },
    },
    .debug = .{
        .aliases = &[_][]const u8{},
        .description = @as(?[]const u8, null),
        .hidden = true,
        .opts = .{
            .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
            .from_file = Opt{ .names = .{ .long = "from-file", .short = 'f' }, .has_arg = .required_argument, .meta = "file", .description = "Load query from file" },
            .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar" },
        },
    },
};

const grammar_subcmds = .{
    .list = .{ .aliases = &[_][]const u8{"ls"}, .description = @as(?[]const u8, "List installed grammars") },
    .add = .{ .aliases = &[_][]const u8{}, .description = @as(?[]const u8, "Install grammars") },
    .remove = .{ .aliases = &[_][]const u8{"rm"}, .description = @as(?[]const u8, "Remove grammars") },
};

const debug_subcmds = .{
    .@"dump-instructions" = .{
        .aliases = &[_][]const u8{},
        .description = @as(?[]const u8, null),
        .hidden = true,
    },
};

const main_cmd = .{
    .name = "tql",
    .opts = main_opts,
    .subcmds = main_cmds,
};

const query_cmd = .{
    .name = "tql query",
    .opts = main_cmds.query.opts,
    .positionals = &[_]Positional{
        .{ .name = "query", .required = false },
        .{ .name = "file", .required = true, .variadic = true },
    },
};

const version_cmd = .{
    .name = "tql version",
};

const grammar_cmd = .{
    .name = "tql grammar",
    .opts = main_cmds.grammar.opts,
    .subcmds = grammar_subcmds,
    .subcmd_label = "SUBCOMMAND",
    .positionals = &[_]Positional{
        .{ .name = "grammar", .required = false, .variadic = true },
    },
};

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

    var tokenizer = ArgTokenizer(main_opts).init(&iter);
    var show_help = false;
    var subcmd: ?[]const u8 = null;

    while (try tokenizer.next()) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
            },
            .positional => |p| {
                subcmd = p;
                break;
            },
            .named_arg => |kv| switch (kv.field) {},
        }
    }

    if (show_help) {
        try printUsage(main_cmd, stderr);
        return @intFromEnum(ExitCode.success);
    }

    const word = subcmd orelse {
        try printUsage(main_cmd, stderr);
        return @intFromEnum(ExitCode.success);
    };

    switch (SubcmdResolver(main_cmds).match(word)) {
        .subcmd => |s| switch (s) {
            .query => return runQuery(
                init.io,
                init.gpa,
                stdout,
                stderr,
                init.environ_map,
                &iter,
            ),
            .version => {
                try printVersion(stdout);
                return @intFromEnum(ExitCode.success);
            },
            .grammar => return runGrammar(
                init.io,
                init.gpa,
                stdout,
                stderr,
                init.environ_map,
                &iter,
            ),
            .debug => return runDebug(
                init.io,
                init.gpa,
                stdout,
                stderr,
                init.environ_map,
                &iter,
            ),
        },
        .unknown => |w| {
            try stderr.print("Error: unknown command '{s}'\n", .{w});
            try printUsage(main_cmd, stderr);
            return @intFromEnum(ExitCode.invalid_args);
        },
    }
}

fn runQuery(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    iter: *std.process.Args.Iterator,
) !u8 {
    const search_paths = try tql.Grammar.resolveSearchPaths(gpa, environ_map);
    defer {
        for (search_paths) |p| gpa.free(p);
        gpa.free(search_paths);
    }
    var registry = tql.GrammarRegistry.init(gpa, search_paths);
    defer registry.deinit();

    var tokenizer = ArgTokenizer(main_cmds.query.opts).init(iter);

    var show_help = false;
    var from_file: ?[]const u8 = null;
    var workers: usize = 1;
    var grammar: ?*const Grammar = null;
    var progress = false;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (try tokenizer.next()) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
                .progress => progress = true,
            },
            .named_arg => |kv| switch (kv.field) {
                .from_file => from_file = kv.value,
                .workers => workers = std.fmt.parseInt(usize, kv.value, 10) catch {
                    try stderr.print("Error: --workers requires a positive integer\n", .{});
                    return @intFromEnum(ExitCode.invalid_args);
                },
                .grammar => grammar = registry.get(kv.value) catch |err| {
                    try stderr.print("Error: grammar '{s}' not found: {t}\n", .{ kv.value, err });
                    return @intFromEnum(ExitCode.invalid_args);
                },
            },
            .positional => |p| try positionals.append(gpa, p),
        }
    }

    if (show_help) {
        try printUsage(query_cmd, stderr);
        return @intFromEnum(ExitCode.success);
    }

    // If --from-file, positionals are all target files.
    // Otherwise, first positional is the inline query, rest are target files.
    const query: []const u8 = if (from_file) |query_file| blk: {
        const file = try std.Io.Dir.cwd().openFile(io, query_file, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        break :blk try file_reader.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    } else blk: {
        if (positionals.items.len == 0) {
            try stderr.print("Error: query is required\n", .{});
            try printUsage(query_cmd, stderr);
            return @intFromEnum(ExitCode.invalid_args);
        }
        break :blk try gpa.dupe(u8, positionals.items[0]);
    };
    defer gpa.free(query);

    // IMPROVE: read stdin if files.len = 0
    const files: []const []const u8 = if (from_file != null)
        positionals.items
    else
        positionals.items[1..];

    const grammar_resolved = grammar orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        try printUsage(query_cmd, stderr);
        return @intFromEnum(ExitCode.invalid_args);
    };

    return run(gpa, io, stdout, stderr, .{
        .query = query,
        .query_target_paths = files,
        .format = .json,
        .grammar = grammar_resolved,
        .workers = workers,
        .stats = false,
        .verbose = false,
        .progress = progress,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.runtime_error);
    };
}

fn runGrammar(
    io: std.Io,
    gpa: std.mem.Allocator,
    _: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    iter: *std.process.Args.Iterator,
) !u8 {
    var tokenizer = ArgTokenizer(main_cmds.grammar.opts).init(iter);

    var show_help = false;
    var install_dir: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (try tokenizer.next()) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
            },
            .named_arg => |kv| switch (kv.field) {
                .install_dir => install_dir = kv.value,
            },
            .positional => |p| try positionals.append(gpa, p),
        }
    }

    if (show_help or positionals.items.len == 0) {
        try printUsage(grammar_cmd, stderr);
        return @intFromEnum(ExitCode.success);
    }

    switch (SubcmdResolver(grammar_subcmds).match(positionals.items[0])) {
        .subcmd => |s| switch (s) {
            .list => return listGrammars(io, gpa, environ_map, stderr),
            .add => {}, // TODO: install grammars
            .remove => {}, // TODO: remove grammars
        },
        .unknown => |w| {
            try stderr.print("Error: unknown grammar subcommand '{s}'\n", .{w});
            try printUsage(grammar_cmd, stderr);
            return @intFromEnum(ExitCode.invalid_args);
        },
    }

    return @intFromEnum(ExitCode.success);
}

fn listGrammars(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
) !u8 {
    const search_paths = try tql.Grammar.resolveSearchPaths(gpa, environ_map);
    defer {
        for (search_paths) |p| gpa.free(p);
        gpa.free(search_paths);
    }
    var registry = tql.GrammarRegistry.init(gpa, search_paths);
    defer registry.deinit();

    const dyn = try registry.listDynamic(io);
    defer {
        for (dyn) |d| {
            gpa.free(d.name);
            gpa.free(d.dir);
        }
        gpa.free(dyn);
    }

    try stderr.writeAll("Built-in grammars:\n");
    if (tql.Grammar.static_grammars.len == 0) {
        try stderr.writeAll("  (none)\n");
    } else {
        for (tql.Grammar.static_grammars) |grammar| try stderr.print("  {s}\n", .{grammar.name});
    }

    try stderr.writeAll("\nDynamic grammars:\n");
    if (dyn.len == 0) {
        try stderr.writeAll("  (none)\n");
    } else {
        for (dyn) |d| try stderr.print("  {s}  {s}\n", .{ d.name, d.dir });
    }

    return @intFromEnum(ExitCode.success);
}

fn runDebug(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    iter: *std.process.Args.Iterator,
) !u8 {
    var tokenizer = ArgTokenizer(main_cmds.debug.opts).init(iter);

    var from_file: ?[]const u8 = null;
    var grammar_name: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (try tokenizer.next()) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => {},
            },
            .named_arg => |kv| switch (kv.field) {
                .from_file => from_file = kv.value,
                .grammar => grammar_name = kv.value,
            },
            .positional => |p| try positionals.append(gpa, p),
        }
    }

    if (positionals.items.len == 0) {
        try stderr.print("Error: debug subcommand required\n", .{});
        return @intFromEnum(ExitCode.invalid_args);
    }

    switch (SubcmdResolver(debug_subcmds).match(positionals.items[0])) {
        .subcmd => |s| switch (s) {
            .@"dump-instructions" => return runDumpInstructions(io, gpa, stdout, stderr, environ_map, from_file, grammar_name, positionals.items[1..]),
        },
        .unknown => |w| {
            try stderr.print("Error: unknown debug subcommand '{s}'\n", .{w});
            return @intFromEnum(ExitCode.invalid_args);
        },
    }
}

fn runDumpInstructions(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    from_file: ?[]const u8,
    grammar_name: ?[]const u8,
    positionals: []const []const u8,
) !u8 {
    const search_paths = try tql.Grammar.resolveSearchPaths(gpa, environ_map);
    defer {
        for (search_paths) |p| gpa.free(p);
        gpa.free(search_paths);
    }
    var registry = tql.GrammarRegistry.init(gpa, search_paths);
    defer registry.deinit();

    const query: []const u8 = if (from_file) |query_file| blk: {
        const file = try std.Io.Dir.cwd().openFile(io, query_file, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        break :blk try file_reader.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    } else blk: {
        if (positionals.len == 0) {
            try stderr.print("Error: query is required\n", .{});
            return @intFromEnum(ExitCode.invalid_args);
        }
        break :blk try gpa.dupe(u8, positionals[0]);
    };
    defer gpa.free(query);

    const gname = grammar_name orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        return @intFromEnum(ExitCode.invalid_args);
    };

    const grammar = registry.get(gname) catch |err| {
        try stderr.print("Error: grammar '{s}' not found: {t}\n", .{ gname, err });
        return @intFromEnum(ExitCode.invalid_args);
    };

    var engine = try Engine.init(.{ .allocator = gpa, .io = io });
    defer engine.deinit();

    var compiled = engine.compile(query, grammar) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.compilation_error);
    };
    defer compiled.deinit();

    for (compiled.instructions(), 0..) |instr, i| {
        try stdout.print("{d:4}: ", .{i});
        try instr.print(stdout);
        try stdout.writeAll("\n");
    }

    return @intFromEnum(ExitCode.success);
}

const Config = struct {
    query: []const u8,
    query_target_paths: []const []const u8,
    format: OutputFormat,
    grammar: *const Grammar,
    workers: usize = 1,
    stats: bool,
    verbose: bool,
    progress: bool,
};

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
    grammar: *const Grammar,
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
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(ctx.*.io, path, ctx.allocator);
    defer ctx.allocator.free(abs);
    var root_dir = try std.Io.Dir.openDirAbsolute(ctx.*.io, abs, .{
        .iterate = true,
    });

    var walker = try root_dir.walk(ctx.*.allocator);
    while (try walker.next(ctx.*.io)) |entry| {
        if (entry.kind == .file and ctx.*.grammar.matchesFileName(entry.basename)) {
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

    var compiled = try engine.compile(config.query, config.grammar);
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
        .grammar = config.grammar,
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
