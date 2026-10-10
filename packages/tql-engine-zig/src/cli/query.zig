const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const common = @import("common.zig");
const FileLoader = @import("FileLoader.zig");
const pipeline = @import("query/pipeline.zig");
const Context = common.Context;
const ExitCode = common.ExitCode;
const Opt = goz.Opt;
const printUsage = goz.printUsage;

pub const command = .{
    .name = "tql query",
    .aliases = &[_][]const u8{"run"},
    .description = "Run a query against files",
    .opts = .{
        .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
        .from_file = Opt{ .names = .{ .long = "from-file", .short = 'f' }, .has_arg = .required_argument, .meta = "file", .description = "Load query from file" },
        .workers = Opt{ .names = .{ .long = "workers", .short = 'w' }, .has_arg = .required_argument, .meta = "n", .description = "Number of workers (default: 1)" },
        .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar" },
        .include = Opt{ .names = .{ .long = "include", .short = 'I' }, .has_arg = .required_argument, .meta = "dir", .description = "Search dir for imported modules; repeatable" },
        .progress = Opt{ .names = .{ .long = "progress" }, .description = "Show progress" },
        .format = Opt{ .names = .{ .long = "format" }, .has_arg = .required_argument, .meta = "format", .description = "Output format: text, json (default: text)" },
    },
    .positionals = &[_]goz.Positional{
        .{ .name = "query", .required = false },
        .{ .name = "file", .required = true, .variadic = true },
    },
};

pub fn run(ctx: *const Context, iter: *std.process.Args.Iterator) !ExitCode {
    const gpa = ctx.gpa;
    const stderr = ctx.stderr;

    var grammars = try common.Grammars.init(gpa, ctx.environ_map);
    defer grammars.deinit(gpa);

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = goz.ArgTokenizer(command.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var from_file: ?[]const u8 = null;
    var workers: usize = 1;
    var grammar: ?*const tql.Grammar = null;
    var progress = false;
    var format: pipeline.OutputFormat = .text;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(gpa);
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return common.reportArgError(stderr, err, arg_diagnostic)) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
                .progress => progress = true,
            },
            .named_arg => |kv| switch (kv.field) {
                .from_file => from_file = kv.value,
                .workers => {
                    workers = std.fmt.parseInt(usize, kv.value, 10) catch 0;
                    if (workers == 0) {
                        try stderr.print("Error: --workers requires a positive integer\n", .{});
                        return .invalid_args;
                    }
                },
                .grammar => grammar = try grammars.get(kv.value, stderr) orelse
                    return .invalid_args,
                .format => format = std.meta.stringToEnum(pipeline.OutputFormat, kv.value) orelse {
                    try stderr.print("Error: unknown format '{s}'\n", .{kv.value});
                    return .invalid_args;
                },
                .include => try includes.append(gpa, kv.value),
            },
            .positional => |p| try positionals.append(gpa, p),
        }
    }

    if (show_help) {
        try printUsage(command, stderr);
        return .success;
    }

    // If --from-file, positionals are all target files.
    // Otherwise, first positional is the inline query, rest are target files.
    const query = try common.loadQuery(ctx.io, gpa, from_file, positionals.items, stderr) orelse {
        if (from_file == null) try printUsage(command, stderr);
        return .invalid_args;
    };
    defer gpa.free(query);

    // IMPROVE: read stdin if files.len = 0
    const files: []const []const u8 = if (from_file != null)
        positionals.items
    else
        positionals.items[1..];

    const grammar_resolved = grammar orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        try printUsage(command, stderr);
        return .invalid_args;
    };

    const module_roots = try FileLoader.moduleRoots(gpa, from_file, includes.items, ctx.environ_map);
    defer gpa.free(module_roots);

    return pipeline.run(ctx, .{
        .query = query,
        .query_path = from_file,
        .module_roots = module_roots,
        .query_target_paths = files,
        .format = format,
        .grammar = grammar_resolved,
        .workers = workers,
        .progress = progress,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return .runtime_error;
    };
}

test {
    _ = pipeline;
}
