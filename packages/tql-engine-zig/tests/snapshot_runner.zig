const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const ts = tql.ts;
const corpus_parser = @import("corpus_parser.zig");
const fmt = @import("fmt.zig");

const Engine = tql.Engine;
const GrammarRegistry = tql.GrammarRegistry;
const Value = tql.Value;

const SectionKind = corpus_parser.SectionKind;

const DEFAULT_CORPUS_DIR = "tests/corpus";

const ansi = fmt.ansi;

const COMPARABLE_SECTIONS = [_]SectionKind{
    .tql_tree,
    .source_tree,
    .bytecode,
    .values,
};

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

    fn addAll(self: *CompareSections) void {
        inline for (COMPARABLE_SECTIONS) |kind| {
            @field(self.fields, @tagName(kind)) = true;
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
    fail_fast: bool = false,
    color: bool = true,
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

    fn init(gpa: std.mem.Allocator, stdout: *std.Io.Writer, opts: Options) TestRunContext {
        return .{
            .gpa = gpa,
            .stdout = stdout,
            .opts = opts,
            .diffs = .empty,
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
    }

    fn addDiff(
        self: *TestRunContext,
        group: []const u8,
        case_name: []const u8,
        section: []const u8,
        expected: []const u8,
        actual: []const u8,
    ) !void {
        try self.diffs.append(self.gpa, .{
            .group = try self.gpa.dupe(u8, group),
            .case_name = try self.gpa.dupe(u8, case_name),
            .section = section,
            .expected = try self.gpa.dupe(u8, expected),
            .actual = try self.gpa.dupe(u8, actual),
        });
    }
};

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

    var ctx = TestRunContext.init(gpa, stdout, opts);
    defer ctx.deinit();

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    const corpus_files = try collectCorpusFiles(gpa, io, opts.corpus_dir);
    defer {
        for (corpus_files) |f| gpa.free(f);
        gpa.free(corpus_files);
    }

    for (corpus_files) |filename| {
        if (opts.file_name) |name| {
            const stem = filename[0 .. filename.len - 4];
            if (!std.mem.eql(u8, stem, name) and !std.mem.eql(u8, filename, name)) continue;
        }
        const result = try testFile(&ctx, io, filename);
        passed += result.passed;
        failed += result.failed;
        skipped += result.skipped;
        if (result.failed_fast) break;
    }

    try stdout.writeByte('\n');
    if (opts.color) {
        if (failed > 0) {
            try stdout.print("{s}✗ {d} failed{s}", .{ ansi.red_bold, failed, ansi.reset });
            try stdout.print("{s}, {d} passed, {d} skipped{s}\n", .{ ansi.dim, passed, skipped, ansi.reset });
        } else {
            try stdout.print("{s}✓ {d} passed{s}", .{ ansi.green_bold, passed, ansi.reset });
            if (skipped > 0) {
                try stdout.print("{s}, {d} skipped{s}", .{ ansi.dim, skipped, ansi.reset });
            }
            try stdout.writeByte('\n');
        }
    } else {
        try stdout.print("{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    }

    if (ctx.diffs.items.len > 0) {
        try stdout.writeByte('\n');
        var last_group: []const u8 = "";
        var last_case: []const u8 = "";
        for (ctx.diffs.items) |d| {
            if (!std.mem.eql(u8, d.group, last_group)) {
                if (opts.color) {
                    try stdout.print("\n{s}{s}{s}\n", .{ ansi.bold, d.group, ansi.reset });
                } else {
                    try stdout.print("\n{s}\n", .{d.group});
                }
                last_group = d.group;
                last_case = "";
            }
            if (!std.mem.eql(u8, d.case_name, last_case)) {
                if (opts.color) {
                    try stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, d.case_name });
                } else {
                    try stdout.print("  FAIL {s}\n", .{d.case_name});
                }
                last_case = d.case_name;
            }
            try printDiff(stdout, d.section, d.expected, d.actual, opts.color);
        }
    }

    return if (failed > 0) 1 else 0;
}

fn collectCorpusFiles(gpa: std.mem.Allocator, io: std.Io, corpus_dir: []const u8) ![][]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sortUnstable([]const u8, files.items, {}, comptime dictionarySort(u8, std.sort.asc(u8)));

    return files.toOwnedSlice(gpa);
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

    const content = try cwd.readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(content);

    var corpus = try corpus_parser.parse(gpa, content);
    defer corpus.deinit();

    const group = filename[0 .. filename.len - 4];

    var result: FileResult = .{ .passed = 0, .failed = 0, .skipped = 0, .failed_fast = false };
    var file_modified = false;
    var file_header_printed = false;

    var directives: std.ArrayList(corpus_parser.UpdateDirective) = .empty;
    defer {
        for (directives.items) |d| {
            for (d.sections) |s| gpa.free(s.new_content);
            gpa.free(d.sections);
        }
        directives.deinit(gpa);
    }

    for (corpus.cases) |tc| {
        if (ctx.opts.include) |pattern| {
            // TODO: regex matching
            if (!std.mem.eql(u8, tc.name, pattern)) {
                result.skipped += 1;
                continue;
            }
        }

        if (!file_header_printed) {
            if (ctx.opts.color) {
                try ctx.stdout.print("\n{s}{s}{s}\n", .{ ansi.bold, group, ansi.reset });
            } else {
                try ctx.stdout.print("\n{s}\n", .{group});
            }
            file_header_printed = true;
        }

        var section_updates: std.ArrayList(corpus_parser.SectionUpdate) = .empty;
        defer section_updates.deinit(gpa);

        const case_result = try testCase(ctx, io, tc, &section_updates, group);
        switch (case_result) {
            .passed, .modified => result.passed += 1,
            .failed => result.failed += 1,
            .skipped => result.skipped += 1,
        }

        if (case_result == .modified) {
            file_modified = true;
            try directives.append(gpa, .{
                .case_name = tc.name,
                .sections = try section_updates.toOwnedSlice(gpa),
            });
        }

        if (ctx.opts.fail_fast and case_result == .failed) {
            result.failed_fast = true;
            break;
        }
    }

    if (file_modified) {
        const bytes = try corpus_parser.applyUpdates(gpa, corpus, directives.items);
        defer gpa.free(bytes);
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    return result;
}

fn testCase(
    ctx: *TestRunContext,
    io: std.Io,
    tc: corpus_parser.TestCase,
    updates: *std.ArrayList(corpus_parser.SectionUpdate),
    group: []const u8,
) !CaseResult {
    const gpa = ctx.gpa;
    var test_gpa: std.heap.DebugAllocator(.{}) = .init;
    const test_alloc = test_gpa.allocator();
    const actual = runTestCase(test_alloc, io, tc) catch |err| {
        _ = test_gpa.deinit();
        if (ctx.opts.color) {
            try ctx.stdout.print(
                "  {s}✗{s} {s} {s}({s}){s}\n",
                .{ ansi.red_bold, ansi.reset, tc.name, ansi.dim, @errorName(err), ansi.reset },
            );
        } else {
            try ctx.stdout.print("  FAIL {s} ({})\n", .{ tc.name, err });
        }
        return .failed;
    };

    var test_failed = false;
    var test_modified = false;

    inline for (COMPARABLE_SECTIONS) |kind| {
        const actual_val = @field(actual, @tagName(kind));
        const section: corpus_parser.Section = @field(tc, @tagName(kind));
        const exp = section.content;

        if (exp.len > 0) {
            if (!std.mem.eql(u8, exp, actual_val)) {
                if (ctx.opts.update.get(kind)) {
                    try updates.append(gpa, .{ .kind = kind, .new_content = try gpa.dupe(u8, actual_val) });
                    test_modified = true;
                } else {
                    if (!test_failed) {
                        if (ctx.opts.color) {
                            try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, tc.name });
                        } else {
                            try ctx.stdout.print("  FAIL {s}\n", .{tc.name});
                        }
                        test_failed = true;
                    }
                    try ctx.addDiff(group, tc.name, kind.name(), exp, actual_val);
                }
            }
        } else if (ctx.opts.update.get(kind)) {
            try updates.append(gpa, .{ .kind = kind, .new_content = try gpa.dupe(u8, actual_val) });
            test_modified = true;
        } else {
            if (!test_failed) {
                if (ctx.opts.color) {
                    try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, tc.name });
                } else {
                    try ctx.stdout.print("  FAIL {s}\n", .{tc.name});
                }
                test_failed = true;
            }
            try ctx.addDiff(group, tc.name, kind.name(), "", actual_val);
        }
    }

    inline for (COMPARABLE_SECTIONS) |kind| test_alloc.free(@field(actual, @tagName(kind)));
    const leaked = test_gpa.deinit() == .leak;

    if (leaked) {
        if (!test_failed) {
            if (ctx.opts.color) {
                try ctx.stdout.print("  {s}✗{s} {s}\n", .{ ansi.red_bold, ansi.reset, tc.name });
            } else {
                try ctx.stdout.print("  FAIL {s}\n", .{tc.name});
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
            try ctx.stdout.print("  {s}~{s} {s}\n", .{ ansi.yellow_bold, ansi.reset, tc.name });
        } else {
            try ctx.stdout.print("  UPDATED {s}\n", .{tc.name});
        }
        return .modified;
    } else {
        if (ctx.opts.color) {
            try ctx.stdout.print("  {s}✓{s} {s}\n", .{ ansi.green, ansi.reset, tc.name });
        } else {
            try ctx.stdout.print("  PASS {s}\n", .{tc.name});
        }
        return .passed;
    }
}

fn runTestCase(allocator: std.mem.Allocator, io: std.Io, tc: corpus_parser.TestCase) !TestOutputs {
    var registry = GrammarRegistry.init(allocator, &.{});
    defer registry.deinit();
    const grammar = try registry.get(tc.grammar);

    var engine = try Engine.init(.{ .allocator = allocator, .io = io });
    defer engine.deinit();

    var ast = try engine.parseQuery(tc.query.content);
    defer ast.deinit(allocator);

    var query = try engine.compile(tc.query.content, grammar);
    defer query.deinit();

    const ts_parser = ts.Parser.create();
    defer ts_parser.destroy();
    try ts_parser.setLanguage(grammar.language);
    const tree = ts_parser.parseString(tc.target.content, null) orelse return error.ParseFailed;
    defer tree.destroy();

    var run_result = try query.run(tc.target.content, allocator, allocator);
    defer run_result.deinit();

    const source_tree_raw = try fmt.formatSourceAst(allocator, tree);
    defer allocator.free(source_tree_raw);
    const source_tree = try allocator.dupe(u8, std.mem.trimEnd(u8, source_tree_raw, "\n"));
    errdefer allocator.free(source_tree);

    const tql_tree_raw = try fmt.formatAst(allocator, ast);
    defer allocator.free(tql_tree_raw);
    const tql_tree = try allocator.dupe(u8, std.mem.trimEnd(u8, tql_tree_raw, "\n"));
    errdefer allocator.free(tql_tree);

    const bytecode_raw = try fmt.formatBytecode(allocator, query.instructions());
    defer allocator.free(bytecode_raw);
    const bytecode = try allocator.dupe(u8, std.mem.trimEnd(u8, bytecode_raw, "\n"));
    errdefer allocator.free(bytecode);

    const values_raw = try fmt.formatValues(allocator, run_result.values.items);
    defer allocator.free(values_raw);
    const actual_values = try allocator.dupe(u8, std.mem.trimEnd(u8, values_raw, "\n"));
    errdefer allocator.free(actual_values);

    return .{
        .source_tree = source_tree,
        .tql_tree = tql_tree,
        .bytecode = bytecode,
        .values = actual_values,
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
        .description = "Update snapshots: all, source_tree, tql_tree, bytecode, values (comma-separated); bare --update updates all",
    },
    .file_name = goz.Opt{
        .names = .{ .long = "file-name" },
        .has_arg = .required_argument,
        .meta = "NAME",
        .description = "Run only the corpus file with this name (with or without .txt)",
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
    .fail_fast = goz.Opt{ .names = .{ .long = "fail-fast" }, .description = "Stop on first failure" },
    .no_color = goz.Opt{ .names = .{ .long = "no-color" }, .description = "Disable color output" },
};

const snapshot_cmd = .{
    .name = "snapshot-test",
    .opts = cli_opts,
    .positionals = &[_]goz.Positional{},
};

fn parseArgs(iter: *std.process.Args.Iterator) !Options {
    var opts = Options{};
    var tokenizer = goz.ArgTokenizer(cli_opts).init(iter);
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
