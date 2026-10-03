const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const ts = tql.ts;
const corpus_parser = @import("corpus_parser.zig");
const fmt = @import("fmt.zig");

const Engine = tql.Engine;
const GrammarRegistry = tql.GrammarRegistry;

const SectionKind = corpus_parser.SectionKind;

const DEFAULT_CORPUS_DIR = "tests/corpus";

const ansi = fmt.ansi;

const COMPARABLE_SECTIONS = [_]SectionKind{
    .values,
    .tql_tree,
    .source_tree,
    .core,
    .simplified,
    .stg,
    .types,
    .@"error",
};

/// Sections still compared for a case that expects a compile error. The query
/// never reaches the runtime, so only the parse-level snapshots and the error
/// itself remain meaningful.
const ERROR_CASE_SECTIONS = [_]SectionKind{
    .tql_tree,
    .source_tree,
    .@"error",
};

fn isErrorCaseSection(kind: SectionKind) bool {
    for (ERROR_CASE_SECTIONS) |k| if (k == kind) return true;
    return false;
}

const CompareSections = struct {
    const Fields = blk: {
        var names: [COMPARABLE_SECTIONS.len][]const u8 = undefined;
        for (COMPARABLE_SECTIONS, 0..) |kind, i| names[i] = @tagName(kind);
        const default: bool = false;
        break :blk @Struct(
            .auto,
            null,
            &names,
            &@as([COMPARABLE_SECTIONS.len]type, @splat(bool)),
            &@splat(.{ .default_value_ptr = @ptrCast(&default) }),
        );
    };

    fields: Fields = .{},

    fn get(self: CompareSections, comptime kind: SectionKind) bool {
        return @field(self.fields, @tagName(kind));
    }

    /// Every section except `error`, which is updated only when named.
    fn addAll(self: *CompareSections) void {
        inline for (COMPARABLE_SECTIONS) |kind| {
            if (kind != .@"error") @field(self.fields, @tagName(kind)) = true;
        }
    }

    fn addSection(self: *CompareSections, s: []const u8) !void {
        inline for (COMPARABLE_SECTIONS) |kind| {
            if (std.mem.eql(u8, s, @tagName(kind))) {
                @field(self.fields, @tagName(kind)) = true;
                return;
            }
        }
        return error.NoSuchSection;
    }
};

const Options = struct {
    help: bool = false,
    update: CompareSections = .{},
    file_name: ?[]const u8 = null,
    include: ?[]const u8 = null,
    corpus_dir: []const u8 = DEFAULT_CORPUS_DIR,
    max_pending: ?u32 = null,
    fail_fast: bool = false,
    color: bool = true,
    jobs: ?u32 = null,
};

const TestOutputs = blk: {
    var names: [COMPARABLE_SECTIONS.len][]const u8 = undefined;
    for (COMPARABLE_SECTIONS, 0..) |kind, i| names[i] = @tagName(kind);
    break :blk @Struct(
        .auto,
        null,
        &names,
        &@as([COMPARABLE_SECTIONS.len]type, @splat([]const u8)),
        &@splat(.{}),
    );
};

const CaseResult = enum { passed, failed, skipped, modified };

const FileResult = struct {
    passed: u32,
    failed: u32,
    skipped: u32,
    /// Sections the case has written but cannot assert yet. Reported so the
    /// count of deferred expectations is visible rather than implicit.
    pending: u32,
    failed_fast: bool,
};

const DiffEntry = struct {
    group: []const u8,
    case_name: []const u8,
    section: []const u8,
    expected: []const u8,
    actual: []const u8,
};

const TestRunContext = struct {
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    opts: Options,
    diffs: std.ArrayList(DiffEntry),
    /// Why the case failed, one entry per distinct cause. Entries are static
    /// strings and are never freed.
    reasons: std.ArrayList([]const u8),
    /// Diagnostics from a stage the case did not expect to fail.
    unexpected: ?[]const u8,

    fn init(gpa: std.mem.Allocator, stdout: *std.Io.Writer, opts: Options) TestRunContext {
        return .{
            .gpa = gpa,
            .stdout = stdout,
            .opts = opts,
            .diffs = .empty,
            .reasons = .empty,
            .unexpected = null,
        };
    }

    fn deinit(self: *TestRunContext) void {
        for (self.diffs.items) |d| {
            self.gpa.free(d.group);
            self.gpa.free(d.case_name);
            self.gpa.free(d.expected);
            self.gpa.free(d.actual);
        }
        self.diffs.deinit(self.gpa);
        self.reasons.deinit(self.gpa);
        if (self.unexpected) |text| self.gpa.free(text);
    }

    fn addReason(self: *TestRunContext, reason: []const u8) !void {
        for (self.reasons.items) |r| if (std.mem.eql(u8, r, reason)) return;
        try self.reasons.append(self.gpa, reason);
    }

    fn addDiff(
        self: *TestRunContext,
        group: []const u8,
        case_name: []const u8,
        section: []const u8,
        expected: []const u8,
        actual: []const u8,
    ) !void {
        try self.addReason(section);
        try self.diffs.append(self.gpa, .{
            .group = try self.gpa.dupe(u8, group),
            .case_name = try self.gpa.dupe(u8, case_name),
            .section = section,
            .expected = try self.gpa.dupe(u8, expected),
            .actual = try self.gpa.dupe(u8, actual),
        });
    }
};

const CaseRun = struct {
    filename: []const u8,
    log: std.Io.Writer.Allocating,
    ctx: TestRunContext,
    ran: bool = false,
    result: FileResult = .{ .passed = 0, .failed = 0, .skipped = 0, .pending = 0, .failed_fast = false },
    duration: std.Io.Duration = .zero,
    err: ?anyerror = null,

    /// Preconditions:
    /// - `self` does not move after this call; `ctx` points into `log`.
    fn init(self: *CaseRun, gpa: std.mem.Allocator, opts: Options, filename: []const u8) void {
        self.* = .{
            .filename = filename,
            .log = .init(gpa),
            .ctx = undefined,
        };
        self.ctx = .init(gpa, &self.log.writer, opts);
    }

    fn deinit(self: *CaseRun) void {
        self.ctx.deinit();
        self.log.deinit();
    }

    fn name(self: *const CaseRun) []const u8 {
        return caseName(self.filename);
    }

    /// Returns whether `--include` selected the case.
    fn executed(self: *const CaseRun) bool {
        return self.result.passed + self.result.failed > 0;
    }
};

/// Times the case on the thread's CPU clock.
/// Stdout shared by concurrently running cases.
const SharedOutput = struct {
    mutex: std.Io.Mutex = .init,
    writer: *std.Io.Writer,

    /// Write `bytes` as one block and flush.
    fn emit(self: *SharedOutput, io: std.Io, bytes: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.writer.writeAll(bytes);
        try self.writer.flush();
    }
};

fn runCase(run: *CaseRun, out: *SharedOutput, io: std.Io) void {
    const started = std.Io.Clock.cpu_thread.now(io);
    defer run.ran = true;
    run.result = testFile(&run.ctx, io, run.filename) catch |err| {
        run.err = err;
        return;
    };
    run.duration = started.untilNow(io, .cpu_thread);
    out.emit(io, run.log.written()) catch |err| {
        run.err = err;
    };
}

/// Run cases from `runs` until none remain. Workers share `next`.
fn runWorker(runs: []CaseRun, next: *std.atomic.Value(usize), out: *SharedOutput, io: std.Io) void {
    while (true) {
        const i = next.fetchAdd(1, .monotonic);
        if (i >= runs.len) return;
        runCase(&runs[i], out, io);
    }
}

const SLOWEST_SHOWN = 5;

fn slowerThan(runs: []const CaseRun, a: usize, b: usize) bool {
    return runs[a].duration.nanoseconds > runs[b].duration.nanoseconds;
}

pub fn dictionarySort(
    comptime T: type,
    comptime lessThanFn: fn (void, T, T) bool,
) fn (void, []const T, []const T) bool {
    return struct {
        pub fn inner(_: void, a: []const T, b: []const T) bool {
            var ord = std.math.Order.eq;
            var i: usize = 0;
            const upper = @min(a.len, b.len);
            while (ord == std.math.Order.eq and i < upper) {
                ord = if (a[i] == b[i])
                    std.math.Order.eq
                else if (lessThanFn({}, a[i], b[i]))
                    std.math.Order.lt
                else
                    std.math.Order.gt;
                i += 1;
            }
            return switch (ord) {
                .eq => if (a.len == b.len)
                    false
                else if (a.len > b.len)
                    true
                else
                    false,
                .lt => true,
                .gt => false,
            };
        }
    }.inner;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_bw.interface.flush() catch {};
    const stdout = &stdout_bw.interface;

    var args_iter = try init.minimal.args.iterateAllocator(gpa);
    defer args_iter.deinit();
    _ = args_iter.next();

    var opts = try parseArgs(&args_iter);

    if (opts.help) {
        try goz.printUsage(snapshot_cmd, stdout);
        return 0;
    }

    if (opts.color) {
        opts.color = try std.Io.File.stdout().isTty(io);
    }

    const corpus_files = try collectCorpusFiles(gpa, io, opts.corpus_dir);
    defer {
        for (corpus_files) |f| gpa.free(f);
        gpa.free(corpus_files);
    }

    var selected: std.ArrayList([]const u8) = .empty;
    defer selected.deinit(gpa);
    for (corpus_files) |filename| {
        if (opts.file_name) |want| {
            // Matches a case path, with or without extension, and a directory
            // prefix so `--file navigation` selects the whole group.
            const name = caseName(filename);
            const is_case = std.mem.eql(u8, name, want) or std.mem.eql(u8, filename, want);
            const is_group = std.mem.startsWith(u8, name, want) and
                name.len > want.len and name[want.len] == '/';
            if (!is_case and !is_group) continue;
        }
        try selected.append(gpa, filename);
    }

    const runs = try gpa.alloc(CaseRun, selected.items.len);
    defer gpa.free(runs);
    for (runs, selected.items) |*run, filename| run.init(gpa, opts, filename);
    defer for (runs) |*run| run.deinit();

    var shared: SharedOutput = .{ .writer = stdout };
    const started = std.Io.Clock.awake.now(io);
    if (opts.fail_fast) {
        for (runs) |*run| {
            runCase(run, &shared, io);
            if (run.err != null or run.result.failed_fast) break;
        }
    } else {
        const jobs = opts.jobs orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1));
        var next: std.atomic.Value(usize) = .init(0);
        var group: std.Io.Group = .init;
        for (0..@max(jobs, 1)) |_| group.async(io, runWorker, .{ runs, &next, &shared, io });
        try group.await(io);
    }
    const elapsed = started.untilNow(io, .awake);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var pending: u32 = 0;

    for (runs) |*run| {
        if (!run.ran) break;
        if (run.err) |err| return err;
        passed += run.result.passed;
        failed += run.result.failed;
        skipped += run.result.skipped;
        pending += run.result.pending;
    }

    try printSlowest(gpa, stdout, runs, opts.color);

    try stdout.writeByte('\n');
    if (opts.color) {
        if (failed > 0) {
            try stdout.print("{s}✗ {d} failed{s}", .{ ansi.red_bold, failed, ansi.reset });
            try stdout.print("{s}, {d} passed, {d} skipped{s}", .{ ansi.dim, passed, skipped, ansi.reset });
        } else {
            try stdout.print("{s}✓ {d} passed{s}", .{ ansi.green_bold, passed, ansi.reset });
            if (skipped > 0) {
                try stdout.print("{s}, {d} skipped{s}", .{ ansi.dim, skipped, ansi.reset });
            }
        }
        try stdout.print("{s} in {f}{s}\n", .{ ansi.dim, elapsed, ansi.reset });
        if (pending > 0) {
            try stdout.print(
                "{s}{d} pending section{s} not asserted{s}\n",
                .{ ansi.yellow_bold, pending, if (pending == 1) "" else "s", ansi.reset },
            );
        }
    } else {
        try stdout.print(
            "{d} passed, {d} failed, {d} skipped, {d} pending in {f}\n",
            .{ passed, failed, skipped, pending, elapsed },
        );
    }

    if (failed > 0) {
        try stdout.writeByte('\n');
        for (runs) |*run| {
            if (!run.ran) break;
            if (run.result.failed == 0) continue;
            try printFailureSummary(stdout, &run.ctx, run.name(), opts.color);
        }
    }

    if (opts.max_pending) |limit| {
        if (pending > limit) {
            try stdout.print(
                "error: {d} pending sections exceeds --max-pending {d}\n",
                .{ pending, limit },
            );
            return 1;
        }
    }

    return if (failed > 0) 1 else 0;
}

/// Print a failed case's reasons, unexpected diagnostics and section diffs.
fn printFailureSummary(stdout: *std.Io.Writer, ctx: *const TestRunContext, name: []const u8, color: bool) !void {
    const reasons = ctx.reasons.items;
    if (color) {
        try stdout.print("{s}✗{s} {s} {s}(", .{ ansi.red_bold, ansi.reset, name, ansi.dim });
    } else {
        try stdout.print("FAIL {s} (", .{name});
    }
    for (reasons, 0..) |r, i| {
        if (i > 0) try stdout.writeAll(", ");
        try stdout.writeAll(r);
    }
    if (color) {
        try stdout.print("){s}\n", .{ansi.reset});
    } else {
        try stdout.writeAll(")\n");
    }
    if (ctx.unexpected) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (color) {
                try stdout.print("    {s}{s}{s}\n", .{ ansi.red, line, ansi.reset });
            } else {
                try stdout.print("    {s}\n", .{line});
            }
        }
    }
    for (ctx.diffs.items) |d| {
        try printDiff(stdout, d.section, d.expected, d.actual, color);
    }
}

/// Prints the slowest executed cases. Prints nothing when every executed case
/// would be listed.
fn printSlowest(gpa: std.mem.Allocator, stdout: *std.Io.Writer, runs: []const CaseRun, color: bool) !void {
    var executed: std.ArrayList(usize) = .empty;
    defer executed.deinit(gpa);
    for (runs, 0..) |*run, i| {
        if (run.ran and run.executed()) try executed.append(gpa, i);
    }
    if (executed.items.len <= SLOWEST_SHOWN) return;

    std.mem.sortUnstable(usize, executed.items, runs, slowerThan);
    if (color) {
        try stdout.print("\n{s}slowest{s}\n", .{ ansi.bold, ansi.reset });
    } else {
        try stdout.writeAll("\nslowest\n");
    }
    for (executed.items[0..SLOWEST_SHOWN]) |i| {
        try stdout.print("  {f} {s}\n", .{ runs[i].duration, runs[i].name() });
    }
}

/// Collects case files recursively. Each file is one case; its path relative to
/// the corpus root is its identity, so `navigation/child.txt` is the case
/// `navigation/child`.
fn collectCorpusFiles(gpa: std.mem.Allocator, io: std.Io, corpus_dir: []const u8) ![][]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".txt")) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.path));
    }

    std.mem.sortUnstable([]const u8, files.items, {}, comptime dictionarySort(u8, std.sort.asc(u8)));

    return files.toOwnedSlice(gpa);
}

/// The case name is its path without the extension, using `/` on every
/// platform so names match what a reader types on the command line.
fn caseName(path: []const u8) []const u8 {
    return path[0 .. path.len - ".txt".len];
}

/// The group is the leading directory component, or the empty string for a
/// case sitting at the corpus root.
fn caseGroup(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return "";
    return name[0..slash];
}

fn testFile(
    ctx: *TestRunContext,
    io: std.Io,
    filename: []const u8,
) !FileResult {
    const gpa = ctx.gpa;
    const cwd = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.opts.corpus_dir, filename });
    defer gpa.free(path);

    const name = caseName(filename);
    const group = caseGroup(name);

    var result: FileResult = .{ .passed = 0, .failed = 0, .skipped = 0, .pending = 0, .failed_fast = false };

    if (ctx.opts.include) |pattern| {
        // TODO: regex matching
        if (std.mem.indexOf(u8, name, pattern) == null) {
            result.skipped += 1;
            return result;
        }
    }

    const content = try cwd.readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(content);

    var corpus = corpus_parser.parse(gpa, content) catch |err| {
        try ctx.addReason(@errorName(err));
        if (ctx.opts.color) {
            try ctx.stdout.print(
                "  {s}✗{s} {s} {s}({s}){s}\n",
                .{ ansi.red_bold, ansi.reset, name, ansi.dim, @errorName(err), ansi.reset },
            );
        } else {
            try ctx.stdout.print("  FAIL {s} ({t})\n", .{ name, err });
        }
        result.failed = 1;
        result.failed_fast = ctx.opts.fail_fast;
        return result;
    };
    defer corpus.deinit();

    var section_updates: std.ArrayList(corpus_parser.SectionUpdate) = .empty;
    defer {
        for (section_updates.items) |s| gpa.free(s.new_content);
        section_updates.deinit(gpa);
    }

    const case_result = try testCase(ctx, io, corpus.case, &section_updates, group, name);
    switch (case_result) {
        .passed, .modified => result.passed += 1,
        .failed => result.failed += 1,
        .skipped => result.skipped += 1,
    }
    result.pending = @intCast(corpus.case.pending.count());

    if (case_result == .modified) {
        const bytes = try corpus_parser.applyUpdates(gpa, corpus, section_updates.items);
        defer gpa.free(bytes);
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    if (ctx.opts.fail_fast and case_result == .failed) {
        result.failed_fast = true;
    }

    return result;
}

fn testCase(
    ctx: *TestRunContext,
    io: std.Io,
    tc: corpus_parser.TestCase,
    updates: *std.ArrayList(corpus_parser.SectionUpdate),
    group: []const u8,
    name: []const u8,
) !CaseResult {
    const gpa = ctx.gpa;
    var test_gpa: std.heap.DebugAllocator(.{}) = .init;
    const test_alloc = test_gpa.allocator();
    var unexpected: ?[]const u8 = null;
    const actual = runTestCase(test_alloc, io, tc, &unexpected) catch |err| {
        defer _ = test_gpa.deinit();
        defer if (unexpected) |text| test_alloc.free(text);
        try ctx.addReason(@errorName(err));
        if (unexpected) |text| ctx.unexpected = try gpa.dupe(u8, text);
        if (ctx.opts.color) {
            try ctx.stdout.print(
                "  {s}✗{s} {s} {s}({s}){s}\n",
                .{ ansi.red_bold, ansi.reset, name, ansi.dim, @errorName(err), ansi.reset },
            );
        } else {
            try ctx.stdout.print("  FAIL {s} ({t})\n", .{ name, err });
        }
        if (unexpected) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (ctx.opts.color) {
                    try ctx.stdout.print("    {s}{s}{s}\n", .{ ansi.red, line, ansi.reset });
                } else {
                    try ctx.stdout.print("    {s}\n", .{line});
                }
            }
        }
        return .failed;
    };

    var test_failed = false;
    var test_modified = false;

    const expects_error = tc.expectsError();

    inline for (COMPARABLE_SECTIONS) |kind| skip: {
        if (expects_error and !isErrorCaseSection(kind)) break :skip;
        // The ratchet: a section is compared only while the case claims it.
        // Anything else populated was rejected at parse time as unasserted, so
        // silence here can only mean a recorded `pending`.
        if (!tc.asserts.has(kind)) break :skip;

        const actual_val = @field(actual, @tagName(kind));
        const section: corpus_parser.Section = tc.section(kind);
        const exp = section.content;

        if (exp.len > 0) {
            if (!try sectionsMatch(gpa, kind, exp, actual_val)) {
                if (ctx.opts.update.get(kind)) {
                    try updates.append(gpa, .{ .kind = kind, .new_content = try gpa.dupe(u8, actual_val) });
                    test_modified = true;
                } else {
                    if (!test_failed) {
                        if (ctx.opts.color) {
                            try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, name });
                        } else {
                            try ctx.stdout.print("  FAIL {s}\n", .{name});
                        }
                        test_failed = true;
                    }
                    try ctx.addDiff(group, name, kind.name(), exp, actual_val);
                }
            }
        } else if (actual_val.len == 0) {
            // Neither side has content: the section has no producer yet, so
            // there is nothing to assert.
            break :skip;
        } else if (ctx.opts.update.get(kind)) {
            try updates.append(gpa, .{ .kind = kind, .new_content = try gpa.dupe(u8, actual_val) });
            test_modified = true;
        } else {
            if (!test_failed) {
                if (ctx.opts.color) {
                    try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, name });
                } else {
                    try ctx.stdout.print("  FAIL {s}\n", .{name});
                }
                test_failed = true;
            }
            try ctx.addDiff(group, name, kind.name(), "", actual_val);
        }
    }

    inline for (COMPARABLE_SECTIONS) |kind| test_alloc.free(@field(actual, @tagName(kind)));
    const leaked = test_gpa.deinit() == .leak;

    if (leaked) {
        try ctx.addReason("memory leak");
        if (!test_failed) {
            if (ctx.opts.color) {
                try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, name });
            } else {
                try ctx.stdout.print("  FAIL {s}\n", .{name});
            }
            test_failed = true;
        }
        if (ctx.opts.color) {
            try ctx.stdout.print("    {s}[memory leak]{s}\n", .{ ansi.red, ansi.reset });
        } else {
            try ctx.stdout.print("    [memory leak]\n", .{});
        }
    }

    if (test_failed) {
        return .failed;
    } else if (test_modified) {
        if (ctx.opts.color) {
            try ctx.stdout.print("  {s}~{s} {s}\n", .{ ansi.yellow_bold, ansi.reset, name });
        } else {
            try ctx.stdout.print("  UPDATED {s}\n", .{name});
        }
        return .modified;
    } else {
        if (ctx.opts.color) {
            try ctx.stdout.print("  {s}✓{s} {s}\n", .{ ansi.green, ansi.reset, name });
        } else {
            try ctx.stdout.print("  PASS {s}\n", .{name});
        }
        return .passed;
    }
}

/// Whether a produced section matches what the case asserts.
///
/// `values` compares as JSON with insignificant whitespace removed. Fixtures
/// lay their expected values out by hand, one output per line with short
/// objects inline, and reformatting 174 of them to match a serializer would
/// cost more than it buys.
fn sectionsMatch(
    gpa: std.mem.Allocator,
    kind: corpus_parser.SectionKind,
    expected: []const u8,
    actual: []const u8,
) !bool {
    if (kind != .values) return std.mem.eql(u8, expected, actual);

    const want = try stripJsonWhitespace(gpa, expected);
    defer gpa.free(want);
    const got = try stripJsonWhitespace(gpa, actual);
    defer gpa.free(got);
    return std.mem.eql(u8, want, got);
}

/// Drops whitespace outside string literals.
fn stripJsonWhitespace(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            try out.append(gpa, c);
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '\r' => {},
            '"' => {
                in_string = true;
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
    }
    return try out.toOwnedSlice(gpa);
}

/// Each diagnostic rendered against `source` as the CLI prints it, separated
/// by blank lines, in report order.
fn describeDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics: []const tql.diagnostic.Diagnostic,
    source: []const u8,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try d.render(&w.writer, source, null);
    }
    const rendered = w.written();
    w.shrinkRetainingCapacity(std.mem.trimEnd(u8, rendered, "\n").len);
    return w.toOwnedSlice();
}

/// Postconditions:
/// - On an unexpected parse, desugar, type or evaluation error, `unexpected`
///   holds the diagnostics, owned by `allocator`.
fn runTestCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    tc: corpus_parser.TestCase,
    unexpected: *?[]const u8,
) !TestOutputs {
    var registry = GrammarRegistry.init(allocator, &.{});
    defer registry.deinit();
    const grammar = try registry.get(tc.grammar);

    var engine = try Engine.init(.{ .allocator = allocator, .io = io });
    defer engine.deinit();

    var parsed = try engine.parseQueryCollecting(tc.query.content);
    defer parsed.deinit();
    const query_cst = parsed.source_file;

    const ts_parser = ts.Parser.create();
    defer ts_parser.destroy();
    try ts_parser.setLanguage(grammar.language);
    const tree = ts_parser.parseString(tc.target.content, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const source_tree_raw = try fmt.formatSourceAst(allocator, tree);
    defer allocator.free(source_tree_raw);
    const source_tree = try allocator.dupe(u8, std.mem.trimEnd(u8, source_tree_raw, "\n"));
    errdefer allocator.free(source_tree);

    const tql_tree_raw = try fmt.formatCst(allocator, query_cst);
    defer allocator.free(tql_tree_raw);
    const tql_tree = try allocator.dupe(u8, std.mem.trimEnd(u8, tql_tree_raw, "\n"));
    errdefer allocator.free(tql_tree);

    // A case carrying an `--- error ---` section asserts the query is
    // rejected, so compilation failure is the expected outcome and every
    // section downstream of it stays empty.
    const expects_error = tc.expectsError();

    // Syntax errors are decided by the parser alone, so they are reported
    // before compilation is even attempted.
    if (parsed.hasErrors()) {
        if (!expects_error) {
            unexpected.* = try describeDiagnostics(allocator, parsed.diagnostics, tc.query.content);
            return error.UnexpectedParseError;
        }
        return .{
            .source_tree = source_tree,
            .tql_tree = tql_tree,
            .values = try allocator.dupe(u8, ""),
            .core = try allocator.dupe(u8, ""),
            .simplified = try allocator.dupe(u8, ""),
            .stg = try allocator.dupe(u8, ""),
            .types = try allocator.dupe(u8, ""),
            .@"error" = try describeDiagnostics(allocator, parsed.diagnostics, tc.query.content),
        };
    }

    // Desugaring runs independently of the rest of compilation: a case may
    // assert its Core term while its values are still pending.
    var core_text: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(core_text);
    var desugar_diagnostics: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(desugar_diagnostics);

    var types_text: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(types_text);
    var simplified_text: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(simplified_text);
    var stg_text: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(stg_text);
    var type_diagnostics: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(type_diagnostics);

    {
        var sink = tql.diagnostic.Sink.init(allocator);
        defer sink.deinit();

        // Through the Engine rather than `desugar.module` directly, so the
        // corpus exercises the same link the compiler performs: the prelude
        // beneath the query, with `main` resolved by the linker.
        if (engine.desugarQuery(tc.query.content, grammar, &sink)) |desugared| {
            var program = desugared;
            defer program.deinit();
            allocator.free(core_text);
            core_text = try fmt.formatCore(allocator, &program);

            if (tc.isAsserted(.types) or tc.isAsserted(.simplified) or tc.isAsserted(.stg) or expects_error) {
                var type_sink = tql.diagnostic.Sink.init(allocator);
                defer type_sink.deinit();

                if (tql.type_check.check(allocator, &program, &type_sink)) {
                    allocator.free(types_text);
                    types_text = try fmt.formatTypes(allocator, &program);

                    if (tc.isAsserted(.simplified) or tc.isAsserted(.stg)) {
                        try tql.core_to_core.run(&program);
                        allocator.free(simplified_text);
                        simplified_text = try fmt.formatCore(allocator, &program);
                    }
                    if (tc.isAsserted(.stg)) {
                        var translated = try tql.core_to_stg.translate(allocator, &program);
                        defer translated.deinit();
                        allocator.free(stg_text);
                        stg_text = try fmt.formatStg(allocator, &program, &translated);
                    }
                } else |err| switch (err) {
                    error.TypeCheckFailed => {
                        allocator.free(type_diagnostics);
                        type_diagnostics = try describeDiagnostics(allocator, type_sink.items(), tc.query.content);
                        if (!expects_error) {
                            unexpected.* = try describeDiagnostics(allocator, type_sink.items(), tc.query.content);
                        }
                    },
                    else => |e| return e,
                }
            }
        } else |err| switch (err) {
            error.DesugarFailed, error.LinkFailed => {
                allocator.free(desugar_diagnostics);
                desugar_diagnostics = try describeDiagnostics(allocator, sink.items(), tc.query.content);
                if (!expects_error) {
                    unexpected.* = try describeDiagnostics(allocator, sink.items(), tc.query.content);
                }
            },
            else => return err,
        }
    }

    // A rejection found by type checking. Core is still reported: the program
    // desugared fine, and its untyped term is what the case may assert.
    if (type_diagnostics.len > 0) {
        if (!expects_error) return error.UnexpectedTypeError;
        allocator.free(types_text);
        return .{
            .source_tree = source_tree,
            .tql_tree = tql_tree,
            .values = try allocator.dupe(u8, ""),
            .core = core_text,
            .simplified = simplified_text,
            .stg = stg_text,
            .types = try allocator.dupe(u8, ""),
            .@"error" = type_diagnostics,
        };
    }

    // A rejection found by desugaring is the case's expected outcome, and
    // nothing downstream of it runs.
    if (desugar_diagnostics.len > 0) {
        if (!expects_error) return error.UnexpectedDesugarError;
        allocator.free(core_text);
        return .{
            .source_tree = source_tree,
            .tql_tree = tql_tree,
            .values = try allocator.dupe(u8, ""),
            .core = try allocator.dupe(u8, ""),
            .simplified = simplified_text,
            .stg = stg_text,
            .types = try allocator.dupe(u8, ""),
            .@"error" = desugar_diagnostics,
        };
    }

    // A case asserting values runs on the evaluator against the parsed target.
    if (tc.isAsserted(.values) and !expects_error) {
        var eval_sink = tql.diagnostic.Sink.init(allocator);
        defer eval_sink.deinit();
        const values = engine.evaluateQuery(
            tc.query.content,
            tc.target.content,
            if (tc.file.len == 0) null else tc.file,
            grammar,
            &eval_sink,
            allocator,
        ) catch |err| {
            if (eval_sink.items().len > 0) {
                unexpected.* = try describeDiagnostics(allocator, eval_sink.items(), tc.query.content);
            }
            return err;
        };
        return .{
            .source_tree = source_tree,
            .tql_tree = tql_tree,
            .values = values,
            .core = core_text,
            .simplified = simplified_text,
            .stg = stg_text,
            .types = types_text,
            .@"error" = try allocator.dupe(u8, ""),
        };
    }

    // Desugaring and type checking already returned above with their
    // diagnostics, so a case reaching here expected a rejection that no stage
    // made.
    if (expects_error) return error.ExpectedCompileError;

    return .{
        .source_tree = source_tree,
        .tql_tree = tql_tree,
        .values = try allocator.dupe(u8, ""),
        .core = core_text,
        .simplified = simplified_text,
        .stg = stg_text,
        .types = types_text,
        .@"error" = try allocator.dupe(u8, ""),
    };
}

fn printDiff(writer: *std.Io.Writer, section: []const u8, expected: []const u8, actual: []const u8, color: bool) !void {
    if (color) {
        try writer.print("    {s}[{s}]{s}\n", .{ ansi.cyan, section, ansi.reset });
    } else {
        try writer.print("    [{s}]\n", .{section});
    }

    var exp_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exp_list.deinit(std.heap.page_allocator);
    var act_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer act_list.deinit(std.heap.page_allocator);

    var it = std.mem.splitScalar(u8, expected, '\n');
    while (it.next()) |line| try exp_list.append(std.heap.page_allocator, line);
    it = std.mem.splitScalar(u8, actual, '\n');
    while (it.next()) |line| try act_list.append(std.heap.page_allocator, line);

    const exp_lines = exp_list.items;
    const act_lines = act_list.items;

    const m = exp_lines.len;
    const n = act_lines.len;

    const dp = try std.heap.page_allocator.alloc(usize, (m + 1) * (n + 1));
    defer std.heap.page_allocator.free(dp);
    @memset(dp, 0);

    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            if (std.mem.eql(u8, exp_lines[i - 1], act_lines[j - 1])) {
                dp[i * (n + 1) + j] = dp[(i - 1) * (n + 1) + (j - 1)] + 1;
            } else {
                dp[i * (n + 1) + j] = @max(dp[(i - 1) * (n + 1) + j], dp[i * (n + 1) + (j - 1)]);
            }
        }
    }

    const Op = enum { keep, remove, add };
    var ops: std.ArrayListUnmanaged(struct { op: Op, line: []const u8 }) = .empty;
    defer ops.deinit(std.heap.page_allocator);

    var i = m;
    var j = n;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, exp_lines[i - 1], act_lines[j - 1])) {
            try ops.append(std.heap.page_allocator, .{ .op = .keep, .line = exp_lines[i - 1] });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * (n + 1) + (j - 1)] >= dp[(i - 1) * (n + 1) + j])) {
            try ops.append(std.heap.page_allocator, .{ .op = .add, .line = act_lines[j - 1] });
            j -= 1;
        } else {
            try ops.append(std.heap.page_allocator, .{ .op = .remove, .line = exp_lines[i - 1] });
            i -= 1;
        }
    }

    std.mem.reverse(@TypeOf(ops.items[0]), ops.items);

    const CONTEXT = 2;

    var idx: usize = 0;
    while (idx < ops.items.len) {
        const entry = ops.items[idx];
        if (entry.op == .keep) {
            var has_nearby_change = false;
            const lo = if (idx >= CONTEXT) idx - CONTEXT else 0;
            const hi = @min(idx + CONTEXT + 1, ops.items.len);
            for (lo..hi) |k| {
                if (ops.items[k].op != .keep) {
                    has_nearby_change = true;
                    break;
                }
            }
            if (!has_nearby_change) {
                idx += 1;
                continue;
            }
        }
        switch (entry.op) {
            .keep => {
                if (color) {
                    try writer.print("    {s}  {s}{s}\n", .{ ansi.dim, entry.line, ansi.reset });
                } else {
                    try writer.print("      {s}\n", .{entry.line});
                }
            },
            .remove => {
                if (color) {
                    try writer.print("    {s}- {s}{s}\n", .{ ansi.red, entry.line, ansi.reset });
                } else {
                    try writer.print("    - {s}\n", .{entry.line});
                }
            },
            .add => {
                if (color) {
                    try writer.print("    {s}+ {s}{s}\n", .{ ansi.green, entry.line, ansi.reset });
                } else {
                    try writer.print("    + {s}\n", .{entry.line});
                }
            },
        }
        idx += 1;
    }
}

const cli_opts = .{
    .help = goz.Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
    .update = goz.Opt{
        .names = .{ .long = "update", .short = 'u' },
        .has_arg = .optional_argument,
        .meta = "SECTIONS",
        .description = "Update snapshots: all, source_tree, tql_tree, values, core, simplified, stg, types, error (comma-separated); bare --update updates all but error",
    },
    .file_name = goz.Opt{
        .names = .{ .long = "file-name" },
        .has_arg = .required_argument,
        .meta = "NAME",
        .description = "Run only this case path, or every case under it (with or without .txt)",
    },
    .max_pending = goz.Opt{
        .names = .{ .long = "max-pending" },
        .has_arg = .required_argument,
        .meta = "N",
        .description = "Fail if more than N sections are written but not yet asserted",
    },
    .include = goz.Opt{
        .names = .{ .long = "include", .short = 'i' },
        .has_arg = .required_argument,
        .meta = "PATTERN",
        .description = "Run only test cases matching this pattern (exact match; TODO: regex)",
    },
    .corpus_dir = goz.Opt{
        .names = .{ .long = "corpus-dir" },
        .has_arg = .required_argument,
        .meta = "DIR",
        .description = "Corpus directory (default: tests/corpus)",
    },
    .jobs = goz.Opt{
        .names = .{ .long = "jobs", .short = 'j' },
        .has_arg = .required_argument,
        .meta = "N",
        .description = "Run N cases at a time (default: number of CPUs)",
    },
    .fail_fast = goz.Opt{ .names = .{ .long = "fail-fast" }, .description = "Stop on first failure; runs cases one at a time" },
    .no_color = goz.Opt{ .names = .{ .long = "no-color" }, .description = "Disable color output" },
};

const snapshot_cmd = .{
    .name = "snapshot-test",
    .opts = cli_opts,
    .positionals = &[_]goz.Positional{},
};

fn parseArgs(iter: *std.process.Args.Iterator) !Options {
    var opts = Options{};
    var tokenizer = goz.ArgTokenizer(cli_opts).init(iter, null);
    while (try tokenizer.next()) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => opts.help = true,
                .fail_fast => opts.fail_fast = true,
                .no_color => opts.color = false,
            },
            .named_arg => |kv| switch (kv.field) {
                .file_name => opts.file_name = kv.value,
                .include => opts.include = kv.value,
                .corpus_dir => opts.corpus_dir = kv.value,
                .max_pending => opts.max_pending = try std.fmt.parseInt(u32, kv.value, 10),
                .jobs => opts.jobs = try std.fmt.parseInt(u32, kv.value, 10),
            },
            .named_opt => |kv| switch (kv.field) {
                .update => {
                    if (kv.value) |v| {
                        if (std.mem.eql(u8, v, "all")) {
                            opts.update.addAll();
                        } else {
                            var it = std.mem.splitScalar(u8, v, ',');
                            while (it.next()) |s| {
                                try opts.update.addSection(s);
                            }
                        }
                    } else {
                        opts.update.addAll();
                    }
                },
            },
            .positional => {},
        }
    }
    return opts;
}

test {
    std.testing.refAllDecls(corpus_parser);
}
