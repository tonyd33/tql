const std = @import("std");
const engine_mod = @import("engine");
const goz = @import("goz");
const ts = engine_mod.ts;
const corpus_parser = @import("corpus_parser.zig");
const snapshot_utils = @import("snapshot_utils.zig");

const Parser = engine_mod.Parser;
const Compiler = engine_mod.Compiler;
const RuntimeMod = engine_mod.Runtime;
const GrammarRegistry = engine_mod.GrammarRegistry;
const Value = engine_mod.Value;

const DEFAULT_CORPUS_DIR = "tests/corpus";

const c = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const green_bold = "\x1b[1;32m";
    const red_bold = "\x1b[1;31m";
    const yellow_bold = "\x1b[1;33m";
};

const UpdateSections = struct {
    tql_ast: bool = false,
    bytecode: bool = false,
    values: bool = false,

    fn all() UpdateSections {
        return .{ .tql_ast = true, .bytecode = true, .values = true };
    }
};

const Options = struct {
    help: bool = false,
    update: UpdateSections = .{},
    filter: ?[]const u8 = null,
    corpus_dir: []const u8 = DEFAULT_CORPUS_DIR,
    fail_fast: bool = false,
    color: bool = true,
};

const ActualOutputs = struct {
    source_ast: []const u8,
    tql_ast: []const u8,
    bytecode: []const u8,
    values: []const u8,

    fn deinit(self: *ActualOutputs, allocator: std.mem.Allocator) void {
        allocator.free(self.source_ast);
        allocator.free(self.tql_ast);
        allocator.free(self.bytecode);
        allocator.free(self.values);
    }
};

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

    // Auto-detect color support from stdout.
    if (opts.color) {
        opts.color = try std.Io.File.stdout().isTty(io);
    }

    var total: u32 = 0;
    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var corpus_dir = try cwd.openDir(io, opts.corpus_dir, .{ .iterate = true });
    defer corpus_dir.close(io);

    var corpus_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (corpus_files.items) |f| gpa.free(f);
        corpus_files.deinit(gpa);
    }

    var dir_iter = corpus_dir.iterate();
    while (try dir_iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try corpus_files.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sortUnstable([]const u8, corpus_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var failed_fast = false;
    for (corpus_files.items) |filename| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.corpus_dir, filename });
        defer gpa.free(path);

        const content = try cwd.readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
        defer gpa.free(content);

        var corpus = try corpus_parser.parse(gpa, content);
        defer corpus.deinit();

        // Strip .txt suffix for display.
        const group = if (std.mem.endsWith(u8, filename, ".txt"))
            filename[0 .. filename.len - 4]
        else
            filename;

        var file_modified = false;
        var file_header_printed = false;

        for (corpus.cases) |*tc| {
            if (opts.filter) |f| {
                if (std.mem.indexOf(u8, tc.name, f) == null) {
                    skipped += 1;
                    continue;
                }
            }

            total += 1;

            if (!file_header_printed) {
                if (opts.color) {
                    try stdout.print("\n{s}{s}{s}\n", .{ c.bold, group, c.reset });
                } else {
                    try stdout.print("\n{s}\n", .{group});
                }
                file_header_printed = true;
            }

            var actual = runTestCase(gpa, tc.*) catch |err| {
                if (opts.color) {
                    try stdout.print("  {s}✗{s} {s} {s}({s}){s}\n", .{ c.red_bold, c.reset, tc.name, c.dim, @errorName(err), c.reset });
                } else {
                    try stdout.print("  FAIL {s} ({})\n", .{ tc.name, err });
                }
                failed += 1;
                if (opts.fail_fast) {
                    failed_fast = true;
                    break;
                }
                continue;
            };
            defer actual.deinit(gpa);

            var test_failed = false;
            var test_modified = false;

            // source_ast is always auto-updated, never causes a test failure.
            if (tc.source_ast == null or !std.mem.eql(u8, tc.source_ast.?, actual.source_ast)) {
                if (tc.source_ast) |s| gpa.free(s);
                tc.source_ast = try gpa.dupe(u8, actual.source_ast);
                test_modified = true;
                file_modified = true;
            }

            const Section = struct {
                name: []const u8,
                actual: []const u8,
                expected: *?[]const u8,
                update: bool,
            };
            const sections = [_]Section{
                .{ .name = "tql ast", .actual = actual.tql_ast, .expected = &tc.expected_tql_ast, .update = opts.update.tql_ast },
                .{ .name = "bytecode", .actual = actual.bytecode, .expected = &tc.expected_bytecode, .update = opts.update.bytecode },
                .{ .name = "values", .actual = actual.values, .expected = &tc.expected_values, .update = opts.update.values },
            };

            for (sections) |sec| {
                if (sec.expected.*) |exp| {
                    if (!std.mem.eql(u8, exp, sec.actual)) {
                        if (sec.update) {
                            gpa.free(exp);
                            sec.expected.* = try gpa.dupe(u8, sec.actual);
                            test_modified = true;
                            file_modified = true;
                        } else {
                            if (!test_failed) {
                                if (opts.color) {
                                    try stdout.print("  {s}✗{s} {s}\n", .{ c.red_bold, c.reset, tc.name });
                                } else {
                                    try stdout.print("  FAIL {s}\n", .{tc.name});
                                }
                                test_failed = true;
                            }
                            try printDiff(stdout, sec.name, exp, sec.actual, opts.color);
                        }
                    }
                } else {
                    sec.expected.* = try gpa.dupe(u8, sec.actual);
                    test_modified = true;
                    file_modified = true;
                }
            }

            if (test_failed) {
                failed += 1;
            } else if (test_modified) {
                if (opts.color) {
                    try stdout.print("  {s}~{s} {s}\n", .{ c.yellow_bold, c.reset, tc.name });
                } else {
                    try stdout.print("  UPDATED {s}\n", .{tc.name});
                }
                passed += 1;
            } else {
                if (opts.color) {
                    try stdout.print("  {s}✓{s} {s}\n", .{ c.green, c.reset, tc.name });
                } else {
                    try stdout.print("  PASS {s}\n", .{tc.name});
                }
                passed += 1;
            }

            if (opts.fail_fast and test_failed) {
                failed_fast = true;
                break;
            }
        }

        if (file_modified) {
            var w = std.Io.Writer.Allocating.init(gpa);
            defer w.deinit();
            try corpus_parser.serialize(&w.writer, corpus.cases);
            const bytes = try w.toOwnedSlice();
            defer gpa.free(bytes);
            try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
        }

        if (failed_fast) break;
    }

    try stdout.writeByte('\n');
    if (opts.color) {
        if (failed > 0) {
            try stdout.print("{s}✗ {d} failed{s}", .{ c.red_bold, failed, c.reset });
            try stdout.print("{s}, {d} passed, {d} skipped{s}\n", .{ c.dim, passed, skipped, c.reset });
        } else {
            try stdout.print("{s}✓ {d} passed{s}", .{ c.green_bold, passed, c.reset });
            if (skipped > 0) {
                try stdout.print("{s}, {d} skipped{s}", .{ c.dim, skipped, c.reset });
            }
            try stdout.writeByte('\n');
        }
    } else {
        try stdout.print("{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    }

    return if (failed > 0) 1 else 0;
}

fn runTestCase(allocator: std.mem.Allocator, tc: corpus_parser.TestCase) !ActualOutputs {
    var registry = GrammarRegistry.init(allocator, &.{});
    defer registry.deinit();
    const language = (try registry.get(tc.grammar)).language;

    var tql_parser = try Parser.init(allocator);
    defer tql_parser.deinit();

    var ast = try tql_parser.parse(tc.query);
    defer ast.deinit(allocator);

    var compiler = Compiler.init(allocator, language);
    defer compiler.deinit();

    var program = try compiler.compile(allocator, ast);
    defer program.deinit();

    const ts_parser = ts.Parser.create();
    defer ts_parser.destroy();

    try ts_parser.setLanguage(language);
    const tree = ts_parser.parseString(tc.target, null) orelse return error.ParseFailed;
    defer tree.destroy();

    var rt = RuntimeMod.Runtime.init(.{
        .tree = tree,
        .source = tc.target,
        .instructions = program.instructions,
        .regexes = program.regexes,
        .allocator = allocator,
    });
    defer rt.deinit();

    try rt.exec();

    var values: std.ArrayList(Value) = .empty;
    defer {
        for (values.items) |*v| v.deinit(allocator);
        values.deinit(allocator);
    }

    while (try rt.next()) |value| {
        const enriched = try Value.fromRuntimeValue(allocator, value, tc.target);
        try values.append(allocator, enriched);
    }

    const actual_source_ast_raw = try snapshot_utils.formatSourceAst(allocator, tree);
    defer allocator.free(actual_source_ast_raw);
    const actual_source_ast = try allocator.dupe(u8, std.mem.trimEnd(u8, actual_source_ast_raw, "\n"));
    errdefer allocator.free(actual_source_ast);

    const actual_tql_ast_raw = try snapshot_utils.formatAst(allocator, ast);
    defer allocator.free(actual_tql_ast_raw);
    const actual_tql_ast = try allocator.dupe(u8, std.mem.trimEnd(u8, actual_tql_ast_raw, "\n"));
    errdefer allocator.free(actual_tql_ast);

    const actual_bytecode_raw = try snapshot_utils.formatBytecode(allocator, program.instructions);
    defer allocator.free(actual_bytecode_raw);
    const actual_bytecode = try allocator.dupe(u8, std.mem.trimEnd(u8, actual_bytecode_raw, "\n"));
    errdefer allocator.free(actual_bytecode);

    const actual_values_raw = try snapshot_utils.formatValues(allocator, values.items);
    defer allocator.free(actual_values_raw);
    const actual_values = try allocator.dupe(u8, std.mem.trimEnd(u8, actual_values_raw, "\n"));
    errdefer allocator.free(actual_values);

    return .{
        .source_ast = actual_source_ast,
        .tql_ast = actual_tql_ast,
        .bytecode = actual_bytecode,
        .values = actual_values,
    };
}

fn printDiff(writer: *std.Io.Writer, section: []const u8, expected: []const u8, actual: []const u8, color: bool) !void {
    if (color) {
        try writer.print("    {s}[{s}]{s}\n", .{ c.cyan, section, c.reset });
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
                    try writer.print("    {s}  {s}{s}\n", .{ c.dim, entry.line, c.reset });
                } else {
                    try writer.print("      {s}\n", .{entry.line});
                }
            },
            .remove => {
                if (color) {
                    try writer.print("    {s}- {s}{s}\n", .{ c.red, entry.line, c.reset });
                } else {
                    try writer.print("    - {s}\n", .{entry.line});
                }
            },
            .add => {
                if (color) {
                    try writer.print("    {s}+ {s}{s}\n", .{ c.green, entry.line, c.reset });
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
    .update = goz.Opt{ .names = .{ .long = "update" }, .has_arg = .optional_argument, .meta = "SECTIONS", .description = "Update snapshots: all, tql-ast, bytecode, values (comma-separated); bare --update updates all" },
    .corpus_dir = goz.Opt{ .names = .{ .long = "corpus-dir" }, .has_arg = .required_argument, .meta = "DIR", .description = "Corpus directory (default: tests/corpus)" },
    .fail_fast = goz.Opt{ .names = .{ .long = "fail-fast" }, .description = "Stop on first failure" },
    .no_color = goz.Opt{ .names = .{ .long = "no-color" }, .description = "Disable color output" },
};

const snapshot_cmd = .{
    .name = "snapshot-test",
    .opts = cli_opts,
    .positionals = &[_]goz.Positional{
        .{ .name = "filter", .required = false },
    },
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
                .corpus_dir => opts.corpus_dir = kv.value,
            },
            .named_opt => |kv| switch (kv.field) {
                .update => {
                    if (kv.value) |v| {
                        if (std.mem.eql(u8, v, "all")) {
                            opts.update = UpdateSections.all();
                        } else {
                            opts.update = .{};
                            var it = std.mem.splitScalar(u8, v, ',');
                            while (it.next()) |s| {
                                if (std.mem.eql(u8, s, "tql-ast")) opts.update.tql_ast = true;
                                if (std.mem.eql(u8, s, "bytecode")) opts.update.bytecode = true;
                                if (std.mem.eql(u8, s, "values")) opts.update.values = true;
                            }
                        }
                    } else {
                        opts.update = UpdateSections.all();
                    }
                },
            },
            .positional => |p| opts.filter = p,
        }
    }
    return opts;
}
