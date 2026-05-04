const std = @import("std");
const tql = @import("tql_engine_zig");
const clap = @import("clap");
const Engine = tql.Engine;
const Language = tql.Language;
const Match = tql.Match;

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

    var stdout_buffer: [8192]u8 = undefined;
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

fn run(
    allocator: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    config: Config,
) !u8 {
    if (config.query_target_paths.len > 1) {
        try stderr.print("Only one file supported right now\n", .{});
        return @intFromEnum(ExitCode.invalid_args);
    }
    const source_path = config.query_target_paths[0];

    // FIXME: We shouldn't need this
    const language = Language.fromPath(config.query_target_paths[0]) orelse {
        try stderr.print("Cannot detect language from '{s}'. Use --language to specify.\n", .{config.query_target_paths[0]});
        return @intFromEnum(ExitCode.invalid_args);
    };

    var tql_parser = try tql.Parser.init(allocator);

    var compiler = tql.Compiler.init(allocator, language.getTreeSitterLanguage());

    // IMPROVE: prolly mmap'ing the file is more efficient
    const query_source = blk: {
        const file = try std.fs.cwd().openFile(config.query_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };

    const query_target = blk: {
        const file = try std.fs.cwd().openFile(source_path, .{});
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

    var query = tql.Query.init(&program_image, language);

    var query_result = try query.run(allocator, query_target);
    query.deinit();

    try formatResult(stdout, allocator, query_result.matches);

    allocator.free(query_target);
    query_result.deinit();
    program_image.deinit();
    return 0;
}

fn formatResult(writer: *std.io.Writer, allocator: std.mem.Allocator, matches: []const Match) !void {
    var jws = std.json.Stringify{ .writer = writer };

    try jws.beginArray();
    for (matches, 0..) |match, i| {
        const capture_count = match.captures.count();
        const keys = try allocator.alloc([]const u8, capture_count);
        defer allocator.free(keys);
        const values = try allocator.alloc(tql.Value, capture_count);
        defer allocator.free(values);

        var iter = match.captures.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| : (idx += 1) {
            keys[idx] = entry.key_ptr.*;
            values[idx] = entry.value_ptr.*;
        }
        var hmu = try std.StringArrayHashMapUnmanaged(tql.Value).init(
            allocator,
            keys,
            values,
        );
        defer hmu.deinit(allocator);
        const captures_map = std.json.ArrayHashMap(tql.Value){ .map = hmu };

        try jws.beginObject();

        try jws.objectField("index");
        try jws.write(i);

        try jws.objectField("node");
        try jws.write(match.node);

        try jws.objectField("captures");
        try captures_map.jsonStringify(&jws);

        try jws.endObject();
    }
    try jws.endArray();
}

fn writeIndent(writer: *std.io.Writer, indent: usize) anyerror!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try writer.print(" ", .{});
    }
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}
