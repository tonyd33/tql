const std = @import("std");
const engine_mod = @import("engine");
const ts = engine_mod.ts;
const corpus_parser = @import("corpus_parser.zig");
const snapshot_utils = @import("snapshot_utils.zig");

const Parser = engine_mod.Parser;
const Compiler = engine_mod.Compiler;
const RuntimeMod = engine_mod.Runtime;
const GrammarRegistry = engine_mod.GrammarRegistry;
const Value = engine_mod.Value;

const DEFAULT_CORPUS_DIR = "tests/corpus";

const UpdateSections = struct {
    ast: bool = false,
    bytecode: bool = false,
    values: bool = false,

    fn all() UpdateSections {
        return .{ .ast = true, .bytecode = true, .values = true };
    }
};

const Options = struct {
    update: UpdateSections = .{},
    filter: ?[]const u8 = null,
    corpus_dir: []const u8 = DEFAULT_CORPUS_DIR,
    fail_fast: bool = false,
};

const ActualOutputs = struct {
    ast: []const u8,
    bytecode: []const u8,
    values: []const u8,

    fn deinit(self: *ActualOutputs, allocator: std.mem.Allocator) void {
        allocator.free(self.ast);
        allocator.free(self.bytecode);
        allocator.free(self.values);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_iter = try init.minimal.args.iterateAllocator(gpa);
    defer args_iter.deinit();
    _ = args_iter.next();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    while (args_iter.next()) |arg| {
        try args_list.append(gpa, arg);
    }

    const opts = try parseArgs(args_list.items);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_bw = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_bw = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stdout_bw.interface.flush() catch {};
    defer stderr_bw.interface.flush() catch {};
    const stdout = &stdout_bw.interface;
    const stderr = &stderr_bw.interface;

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

        var file_modified = false;

        for (corpus.cases) |*tc| {
            if (opts.filter) |f| {
                if (std.mem.indexOf(u8, tc.name, f) == null) {
                    skipped += 1;
                    continue;
                }
            }

            total += 1;

            var actual = runTestCase(gpa, tc.*) catch |err| {
                try stderr.print("ERROR  {s}: {s} — {}\n", .{ filename, tc.name, err });
                failed += 1;
                if (opts.fail_fast) {
                    failed_fast = true;
                    break;
                }
                continue;
            };
            defer actual.deinit(gpa);

            var test_failed = false;

            const Section = struct {
                name: []const u8,
                actual: []const u8,
                expected: *?[]const u8,
                update: bool,
            };
            const sections = [_]Section{
                .{ .name = "ast", .actual = actual.ast, .expected = &tc.expected_ast, .update = opts.update.ast },
                .{ .name = "bytecode", .actual = actual.bytecode, .expected = &tc.expected_bytecode, .update = opts.update.bytecode },
                .{ .name = "values", .actual = actual.values, .expected = &tc.expected_values, .update = opts.update.values },
            };

            for (sections) |sec| {
                if (sec.expected.*) |exp| {
                    if (!std.mem.eql(u8, exp, sec.actual)) {
                        if (sec.update) {
                            gpa.free(exp);
                            sec.expected.* = try gpa.dupe(u8, sec.actual);
                            file_modified = true;
                        } else {
                            if (!test_failed) {
                                try stderr.print("FAIL   {s}: {s}\n", .{ filename, tc.name });
                                test_failed = true;
                            }
                            try printDiff(stderr, sec.name, exp, sec.actual);
                        }
                    }
                } else {
                    sec.expected.* = try gpa.dupe(u8, sec.actual);
                    file_modified = true;
                }
            }

            if (test_failed) {
                failed += 1;
            } else {
                if (file_modified) {
                    try stdout.print("UPDATED {s}: {s}\n", .{ filename, tc.name });
                } else {
                    try stdout.print("PASS   {s}: {s}\n", .{ filename, tc.name });
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

    try stdout.print("\n{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    if (failed > 0) std.process.exit(1);
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

    const actual_ast_raw = try snapshot_utils.formatAst(allocator, ast);
    defer allocator.free(actual_ast_raw);
    const actual_ast = try allocator.dupe(u8, std.mem.trimEnd(u8,actual_ast_raw, "\n"));
    errdefer allocator.free(actual_ast);

    const actual_bytecode_raw = try snapshot_utils.formatBytecode(allocator, program.instructions);
    defer allocator.free(actual_bytecode_raw);
    const actual_bytecode = try allocator.dupe(u8, std.mem.trimEnd(u8,actual_bytecode_raw, "\n"));
    errdefer allocator.free(actual_bytecode);

    const actual_values_raw = try snapshot_utils.formatValues(allocator, values.items);
    defer allocator.free(actual_values_raw);
    const actual_values = try allocator.dupe(u8, std.mem.trimEnd(u8,actual_values_raw, "\n"));
    errdefer allocator.free(actual_values);

    return .{
        .ast = actual_ast,
        .bytecode = actual_bytecode,
        .values = actual_values,
    };
}

fn printDiff(writer: *std.Io.Writer, section: []const u8, expected: []const u8, actual: []const u8) !void {
    try writer.print("       [{s}] mismatch:\n", .{section});
    try writer.writeAll("       expected:\n");
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    while (exp_lines.next()) |line| {
        try writer.print("         - {s}\n", .{line});
    }
    try writer.writeAll("       actual:\n");
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    while (act_lines.next()) |line| {
        try writer.print("         + {s}\n", .{line});
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--update")) {
            opts.update = UpdateSections.all();
        } else if (std.mem.startsWith(u8, arg, "--update=")) {
            const sections_str = arg["--update=".len..];
            opts.update = .{};
            var it = std.mem.splitScalar(u8, sections_str, ',');
            while (it.next()) |s| {
                if (std.mem.eql(u8, s, "ast")) opts.update.ast = true;
                if (std.mem.eql(u8, s, "bytecode")) opts.update.bytecode = true;
                if (std.mem.eql(u8, s, "values")) opts.update.values = true;
            }
        } else if (std.mem.eql(u8, arg, "--corpus-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingCorpusDir;
            opts.corpus_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--corpus-dir=")) {
            opts.corpus_dir = arg["--corpus-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            opts.fail_fast = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            opts.filter = arg;
        }
    }
    return opts;
}
