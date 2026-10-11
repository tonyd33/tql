const std = @import("std");
const builtin = @import("builtin");
const tql = @import("tql");
const common = @import("../common.zig");
const FileLoader = @import("../FileLoader.zig");
const Grammar = tql.Grammar;
const ExitCode = common.ExitCode;

pub const OutputFormat = enum {
    // IMPROVE: actually implement these
    text,
    json,
    locations,
};

/// A file or directory to query, or standard input's contents.
pub const Target = union(enum) {
    path: []const u8,
    stdin: []const u8,
};

pub const Config = struct {
    query: []const u8,
    /// The file `query` was read from, or null for an inline query.
    query_path: ?[]const u8,
    /// Where `import A.B` looks for `A/B.tql`, in order.
    module_roots: []const []const u8,
    targets: []const Target,
    format: OutputFormat,
    grammar: *const Grammar,
    workers: usize = 1,
    progress: bool,
};

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

fn progressThread(io: std.Io, p: *Progress, stop: *std.atomic.Value(bool), stderr: *Stderr) !void {
    while (!stop.load(.acquire)) {
        {
            try stderr.lock.lock(io);
            defer stderr.lock.unlock(io);
            renderProgress(stderr.writer, p.done.load(.monotonic), p.total.load(.monotonic), p.done_walk.load(.acquire));
        }
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .real);
    }
    try stderr.lock.lock(io);
    defer stderr.lock.unlock(io);
    renderProgress(stderr.writer, p.done.load(.monotonic), p.total.load(.monotonic), p.done_walk.load(.acquire));
    stderr.writer.print("\n", .{}) catch {};
    stderr.writer.flush() catch {};
}

/// stderr, shared by the progress bar and the per-file error reports.
// FIXME: I'm pretty sure there is a threadsafe version of this in 0.16 stdlib
const Stderr = struct {
    writer: *std.Io.Writer,
    lock: std.Io.Mutex = .init,
};

// IMPROVE: almost much everything below belongs in the lib. We're trying to
// "feel out" an appropriate engine API from CLI usage.

const PathEntry = struct {
    /// Held by pointer: an `ArenaAllocator`'s `allocator()` vtable points at
    /// the struct, so moving one through a queue dangles every allocation
    /// made through it.
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    /// Standard input's contents for the `-` target, read in place of `path`.
    contents: ?[]const u8 = null,
};

const PathQueue = tql.ds.BlockingQueue(PathEntry);

const FileStats = struct {
    read_time: std.Io.Duration = .zero,
    parse_time: std.Io.Duration = .zero,
    query_time: std.Io.Duration = .zero,
};

fn writeStats(jws: *std.json.Stringify, stats: FileStats, peak_rss: ?u64, compile: ?tql.CompileTimes) !void {
    try jws.beginObject();
    if (compile) |times| {
        try jws.objectField("compile");
        try jws.write(times);
    }
    try jws.objectField("read_time_ns");
    try jws.write(stats.read_time.nanoseconds);
    try jws.objectField("parse_time_ns");
    try jws.write(stats.parse_time.nanoseconds);
    try jws.objectField("query_time_ns");
    try jws.write(stats.query_time.nanoseconds);
    if (peak_rss) |bytes| {
        try jws.objectField("peak_rss_bytes");
        try jws.write(bytes);
    }
    try jws.endObject();
}

fn peakRss() ?u64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss * 1024),
        .macos => @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss),
        else => null,
    };
}

const FileResult = struct {
    /// Held by pointer for the same reason as `PathEntry.arena`, and owned by
    /// the consumer: `deinit` frees the arena and the cell holding it.
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    filename: []const u8,
    /// The file's outputs, already rendered as a JSON array. Serialization
    /// happens on the worker, while the parsed tree a node value borrows is
    /// still alive.
    values: []const u8,
    count: usize,
    syntax_errors: []const tql.SyntaxError = &.{},
    stats: FileStats,
    /// Why the file produced no outputs, when reading or running it failed.
    failure: ?anyerror = null,

    fn deinit(self: FileResult) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }
};

const ResultQueue = tql.ds.BlockingQueue(FileResult);

const Progress = struct {
    done: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    done_walk: std.atomic.Value(bool) = .init(false),
    /// Files that produced at least one output.
    matched: std.atomic.Value(usize) = .init(0),
    /// Paths that could not be walked, read or run.
    failed: std.atomic.Value(usize) = .init(0),
    /// Files that ran over a tree recovered from syntax errors.
    unparsed: std.atomic.Value(usize) = .init(0),
};

const SharedContext = struct {
    compiled: *const tql.CompiledQuery,
    targets: []const Target,
    allocator: std.mem.Allocator,
    result_queue: *ResultQueue,
    path_queue: *PathQueue,
    grammar: *const Grammar,
    progress: *Progress,
    io: std.Io,
    format: OutputFormat,
};

/// A fresh arena holding `segments` joined as one path.
fn ownPath(ctx: *SharedContext, segments: []const []const u8) !PathEntry {
    const arena = try ctx.allocator.create(std.heap.ArenaAllocator);
    errdefer ctx.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(ctx.allocator);
    errdefer arena.deinit();
    return .{ .arena = arena, .path = try std.fs.path.join(arena.allocator(), segments) };
}

fn pushFile(ctx: *SharedContext, segments: []const []const u8) !void {
    try pushEntry(ctx, try ownPath(ctx, segments));
}

fn pushStdin(ctx: *SharedContext, contents: []const u8) !void {
    var entry = try ownPath(ctx, &.{"<stdin>"});
    entry.contents = contents;
    try pushEntry(ctx, entry);
}

fn pushEntry(ctx: *SharedContext, entry: PathEntry) !void {
    errdefer {
        entry.arena.deinit();
        ctx.allocator.destroy(entry.arena);
    }
    try ctx.path_queue.push(entry);
    _ = ctx.progress.total.fetchAdd(1, .monotonic);
}

/// Report `path` as failed without queueing it for a worker.
///
/// Preconditions:
/// - the path queue is still open, so the result queue is too
fn pushFailure(ctx: *SharedContext, segments: []const []const u8, err: anyerror) !void {
    const entry = try ownPath(ctx, segments);
    _ = ctx.progress.total.fetchAdd(1, .monotonic);
    _ = ctx.progress.done.fetchAdd(1, .monotonic);
    const result = failedResult(ctx, entry, err);
    ctx.result_queue.push(result) catch |push_err| {
        result.deinit();
        return push_err;
    };
}

fn failedResult(ctx: *SharedContext, entry: PathEntry, err: anyerror) FileResult {
    _ = ctx.progress.failed.fetchAdd(1, .monotonic);
    return .{
        .arena = entry.arena,
        .gpa = ctx.allocator,
        .filename = entry.path,
        .values = "",
        .count = 0,
        .stats = .{},
        .failure = err,
    };
}

/// Queue every file under the directory `path` the grammar reads. A
/// subdirectory that cannot be read is reported, and the walk goes on.
fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, path, ctx.allocator);
    defer ctx.allocator.free(abs);
    var root_dir = try std.Io.Dir.openDirAbsolute(ctx.io, abs, .{
        .iterate = true,
    });
    defer root_dir.close(ctx.io);

    var walker = try root_dir.walkSelectively(ctx.allocator);
    defer walker.deinit();
    while (true) {
        // A failed directory is popped, so the next call continues past it.
        const entry = walker.next(ctx.io) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try pushFailure(ctx, &.{path}, err);
                continue;
            },
        } orelse break;
        switch (entry.kind) {
            .directory => walker.enter(ctx.io, entry) catch |err| try pushFailure(ctx, &.{ path, entry.path }, err),
            .file => if (ctx.grammar.matchesFileName(entry.basename)) try pushFile(ctx, &.{ path, entry.path }),
            else => {},
        }
    }
}

fn walkerThread(ctx: *SharedContext) !void {
    // Workers wait on the path queue until it closes, so it closes however
    // the walk ends.
    defer ctx.path_queue.close() catch {};
    defer ctx.progress.done_walk.store(true, .release);

    for (ctx.targets) |target| switch (target) {
        .stdin => |contents| try pushStdin(ctx, contents),
        .path => |path| walkPush(ctx, path) catch |err| switch (err) {
            error.NotDir => try pushFile(ctx, &.{path}),
            else => try pushFailure(ctx, &.{path}, err),
        },
    };
}

fn writerThreadText(ctx: *SharedContext, stdout: *std.Io.Writer, stderr: *Stderr) !void {
    while (try ctx.result_queue.pop()) |result| {
        defer result.deinit();
        if (result.failure) |err| {
            try stderr.lock.lock(ctx.io);
            defer stderr.lock.unlock(ctx.io);
            try stderr.writer.print("{s}: error: {f}\n", .{ result.filename, common.TargetFailure{ .err = err } });
            try stderr.writer.flush();
            continue;
        }
        if (result.syntax_errors.len > 0) {
            try stderr.lock.lock(ctx.io);
            defer stderr.lock.unlock(ctx.io);
            try warnSyntaxErrors(stderr.writer, result.filename, result.syntax_errors, ctx.grammar.name);
            try stderr.writer.flush();
        }
        if (result.count == 0) continue;
        try stdout.print("{s}: {s}\n", .{ result.filename, result.values });
    }
}

/// Print one line for a file that does not parse, at its first syntax error.
///
/// Preconditions:
/// - `errors` is not empty
fn warnSyntaxErrors(w: *std.Io.Writer, filename: []const u8, errors: []const tql.SyntaxError, grammar: []const u8) !void {
    const first = errors[0].start_point;
    try w.print("{s}:{d}:{d}: warning: {d} syntax error{s} under the {s} grammar; findings may be incomplete\n", .{
        filename,
        first.row + 1,
        first.column + 1,
        errors.len,
        if (errors.len == 1) "" else "s",
        grammar,
    });
}

/// Write `filename` as a JSON string, with each ill-formed UTF-8 sequence
/// replaced by U+FFFD.
fn writeFilename(jws: *std.json.Stringify, gpa: std.mem.Allocator, filename: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(filename)) return jws.write(filename);
    const decoded = try std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(filename)});
    defer gpa.free(decoded);
    try jws.write(decoded);
}

fn writerThreadJson(ctx: *SharedContext, jws: *std.json.Stringify) !void {
    var totals: FileStats = .{};
    try jws.beginObject();
    try jws.objectField("results");
    try jws.beginArray();
    while (try ctx.result_queue.pop()) |result| {
        defer result.deinit();
        if (result.failure) |err| {
            try jws.beginObject();
            try jws.objectField("file");
            try writeFilename(jws, ctx.allocator, result.filename);
            try jws.objectField("error");
            try jws.write(@errorName(err));
            try jws.objectField("message");
            const message = try std.fmt.allocPrint(ctx.allocator, "{f}", .{common.TargetFailure{ .err = err }});
            defer ctx.allocator.free(message);
            try jws.write(message);
            try jws.endObject();
            continue;
        }
        totals.read_time = std.Io.Duration.fromNanoseconds(totals.read_time.nanoseconds + result.stats.read_time.nanoseconds);
        totals.parse_time = std.Io.Duration.fromNanoseconds(totals.parse_time.nanoseconds + result.stats.parse_time.nanoseconds);
        totals.query_time = std.Io.Duration.fromNanoseconds(totals.query_time.nanoseconds + result.stats.query_time.nanoseconds);
        try jws.beginObject();
        try jws.objectField("file");
        try writeFilename(jws, ctx.allocator, result.filename);
        try jws.objectField("values");
        try jws.beginWriteRaw();
        try jws.writer.writeAll(result.values);
        jws.endWriteRaw();
        try jws.objectField("syntax_errors");
        try jws.write(result.syntax_errors);
        try jws.objectField("stats");
        try writeStats(jws, result.stats, null, null);
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("stats");
    try writeStats(jws, totals, peakRss(), ctx.compiled.times);
    try jws.endObject();
}

/// How much of one file's scratch a worker keeps for the next. A file that
/// needed more has the excess released instead of held for the rest of the run.
const worker_scratch_retained = 64 * 1024 * 1024;

/// The most scratch one file may hold. A file that needs more fails with
/// `OutOfMemory` and the run continues with the next.
const worker_scratch_limit = 4 * 1024 * 1024 * 1024;

/// Refuse allocations once `limit` bytes have gone through it since the last
/// `reset`. Freed bytes are not refunded. Not thread-safe.
const ScratchBudget = struct {
    child: std.mem.Allocator,
    limit: usize,
    spent: usize = 0,

    fn allocator(self: *ScratchBudget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn reset(self: *ScratchBudget) void {
        self.spent = 0;
    }

    /// Charge the growth from `old_len` to `new_len`, or return false if it
    /// would pass the limit.
    fn charge(self: *ScratchBudget, old_len: usize, new_len: usize) bool {
        if (new_len <= old_len) return true;
        if (new_len - old_len > self.limit - self.spent) return false;
        self.spent += new_len - old_len;
        return true;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(0, len)) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(memory.len, new_len)) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        if (!self.charge(memory.len, new_len)) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ScratchBudget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn workerThread(ctx: *SharedContext) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    defer arena.deinit();
    var budget: ScratchBudget = .{ .child = arena.allocator(), .limit = worker_scratch_limit };

    while (try ctx.path_queue.pop()) |entry| {
        defer {
            _ = arena.reset(.{ .retain_with_limit = worker_scratch_retained });
            budget.reset();
            _ = ctx.progress.done.fetchAdd(1, .monotonic);
        }

        // A file that cannot be read or run is reported and skipped.
        const result = queryFile(ctx, entry, budget.allocator()) catch |err|
            failedResult(ctx, entry, err);
        if (result.count > 0) _ = ctx.progress.matched.fetchAdd(1, .monotonic);
        if (result.syntax_errors.len > 0) _ = ctx.progress.unparsed.fetchAdd(1, .monotonic);

        ctx.result_queue.push(result) catch |err| {
            result.deinit();
            return err;
        };
    }
}

/// Map the file at `path` read-only. Empty for an empty file.
fn mapFile(io: std.Io, path: []const u8) ![]align(std.heap.page_size_min) const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0) return &.{};
    return std.posix.mmap(
        null,
        stat.size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

/// Read and run one target, rendering its outputs into the entry's arena.
fn queryFile(ctx: *SharedContext, entry: PathEntry, scratch: std.mem.Allocator) !FileResult {
    const read_start = std.Io.Timestamp.now(ctx.io, .real);
    const mapped: []align(std.heap.page_size_min) const u8 = if (entry.contents != null) &.{} else try mapFile(ctx.io, entry.path);
    const read_time = read_start.untilNow(ctx.io, .real);
    defer if (mapped.len > 0) std.posix.munmap(mapped);
    const target: []const u8, const target_path: ?[]const u8 = if (entry.contents) |contents|
        .{ contents, null }
    else
        .{ mapped, entry.path };

    const run_result = try ctx.compiled.run(
        target,
        target_path,
        entry.arena.allocator(),
        scratch,
    );

    return .{
        .arena = entry.arena,
        .gpa = ctx.allocator,
        .filename = entry.path,
        .values = run_result.json,
        .count = run_result.count,
        .syntax_errors = run_result.syntax_errors,
        .stats = .{
            .read_time = read_time,
            .parse_time = run_result.parse_time,
            .query_time = run_result.query_time,
        },
    };
}

pub fn run(context: *const common.Context, config: Config) !ExitCode {
    const allocator = context.gpa;
    const io = context.io;
    const stdout = context.stdout;
    const stderr = context.stderr;

    var engine = try tql.Engine.init(.{
        .allocator = allocator,
        .io = io,
    });
    defer engine.deinit();
    var files: FileLoader = .{ .io = io, .gpa = allocator, .roots = config.module_roots };
    defer files.deinit();
    engine.loader = files.loader();

    var sink = tql.diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var compiled = engine.compileQuery(config.query, config.grammar, &sink) catch |err| {
        try common.reportDiagnostics(&engine, &sink, config.query, config.query_path, stderr);
        if (!sink.hasErrors()) try stderr.print("Error: {}\n", .{err});
        return .compilation_error;
    };
    defer compiled.deinit();

    // real shit
    var jws: std.json.Stringify = .{ .writer = stdout };
    var path_queue = try PathQueue.init(allocator, io, 65535);
    var result_queue = try ResultQueue.init(allocator, io, 1024);
    var progress = Progress{};
    var ctx = SharedContext{
        .compiled = &compiled,
        .targets = config.targets,
        .allocator = allocator,
        .result_queue = &result_queue,
        .path_queue = &path_queue,
        .grammar = config.grammar,
        .progress = &progress,
        .io = io,
        .format = config.format,
    };

    var shared_stderr: Stderr = .{ .writer = stderr };
    var progress_stop = std.atomic.Value(bool).init(false);
    var walker_thread = try std.Thread.spawn(.{}, walkerThread, .{&ctx});
    const writer_thread = switch (config.format) {
        .text => try std.Thread.spawn(.{}, writerThreadText, .{ &ctx, stdout, &shared_stderr }),
        .json, .locations => try std.Thread.spawn(.{}, writerThreadJson, .{ &ctx, &jws }),
    };
    const progress_thread = if (config.progress) try std.Thread.spawn(.{}, progressThread, .{ io, &progress, &progress_stop, &shared_stderr }) else null;
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

    if (tql.stg.count_allocations) {
        var total: u64 = 0;
        for (tql.stg.site_counts.values) |c| total += c.load(.monotonic);
        try stderr.print("allocations by site (total {d}):\n", .{total});
        inline for (@typeInfo(tql.stg.Site).@"enum".fields) |f| {
            const site: tql.stg.Site = @enumFromInt(f.value);
            const n = tql.stg.site_counts.get(site).load(.monotonic);
            if (n > 0) try stderr.print("  {d:>10}  {d:>10} B  {s}\n", .{
                n, tql.stg.site_bytes.get(site).load(.monotonic), f.name,
            });
        }
    }

    path_queue.deinit(allocator);
    result_queue.deinit(allocator);
    allocator.free(workers);

    if (progress.failed.load(.monotonic) > 0) return .runtime_error;
    if (progress.unparsed.load(.monotonic) > 0) return .parse_error;
    return .success;
}
test "a scratch budget refuses what would pass its limit" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    const a = try gpa.alloc(u8, 60);
    defer gpa.free(a);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 41));
    const b = try gpa.alloc(u8, 40);
    defer gpa.free(b);
    try std.testing.expectEqual(100, budget.spent);
}

test "a scratch budget does not refund freed bytes" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    gpa.free(try gpa.alloc(u8, 60));
    try std.testing.expectEqual(60, budget.spent);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 41));
}

test "a scratch budget charges growth and not shrinking" {
    var budget: ScratchBudget = .{ .child = std.testing.allocator, .limit = 100 };
    const gpa = budget.allocator();

    var memory = try gpa.alloc(u8, 50);
    defer gpa.free(memory);
    try std.testing.expect(!gpa.resize(memory, 101));
    try std.testing.expectEqual(50, budget.spent);
    if (gpa.resize(memory, 10)) memory = memory[0..10];
    try std.testing.expectEqual(50, budget.spent);
}

test "a scratch budget admits its limit again after a reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget: ScratchBudget = .{ .child = arena.allocator(), .limit = 64 * 1024 };
    const gpa = budget.allocator();

    _ = try gpa.alloc(u8, 48 * 1024);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 48 * 1024));
    _ = arena.reset(.free_all);
    budget.reset();
    _ = try gpa.alloc(u8, 48 * 1024);
}
