const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const common = @import("common.zig");
const FileLoader = @import("FileLoader.zig");
const Context = common.Context;
const ExitCode = common.ExitCode;
const Opt = goz.Opt;

const subcmds = .{
    .@"dump-instructions" = .{
        .hidden = true,
    },
};

pub const command = .{
    .name = "tql debug",
    .hidden = true,
    .opts = .{
        .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
        .from_file = Opt{ .names = .{ .long = "from-file", .short = 'f' }, .has_arg = .required_argument, .meta = "file", .description = "Load query from file" },
        .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar" },
        .include = Opt{ .names = .{ .long = "include", .short = 'I' }, .has_arg = .required_argument, .meta = "dir", .description = "Search dir for imported modules; repeatable" },
    },
};

pub fn run(ctx: *const Context, iter: *std.process.Args.Iterator) !ExitCode {
    const gpa = ctx.gpa;
    const stderr = ctx.stderr;

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = goz.ArgTokenizer(command.opts).init(iter, &arg_diagnostic);

    var from_file: ?[]const u8 = null;
    var grammar_name: ?[]const u8 = null;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(gpa);
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return common.reportArgError(stderr, err, arg_diagnostic)) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => {},
            },
            .named_arg => |kv| switch (kv.field) {
                .from_file => from_file = kv.value,
                .grammar => grammar_name = kv.value,
                .include => try includes.append(gpa, kv.value),
            },
            .positional => |p| try positionals.append(gpa, p),
        }
    }

    if (positionals.items.len == 0) {
        try stderr.print("Error: debug subcommand required\n", .{});
        return .invalid_args;
    }

    switch (goz.SubcmdResolver(subcmds).match(positionals.items[0])) {
        .subcmd => |s| switch (s) {
            .@"dump-instructions" => {
                const module_roots = try FileLoader.moduleRoots(gpa, from_file, includes.items, ctx.environ_map);
                defer gpa.free(module_roots);
                return dumpInstructions(ctx, from_file, module_roots, grammar_name, positionals.items[1..]);
            },
        },
        .unknown => |w| {
            try stderr.print("Error: unknown debug subcommand '{s}'\n", .{w});
            return .invalid_args;
        },
    }
}

fn dumpInstructions(
    ctx: *const Context,
    from_file: ?[]const u8,
    module_roots: []const []const u8,
    grammar_name: ?[]const u8,
    positionals: []const []const u8,
) !ExitCode {
    const io = ctx.io;
    const gpa = ctx.gpa;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;

    var grammars = try common.Grammars.init(gpa, ctx.environ_map);
    defer grammars.deinit(gpa);

    const query = try common.loadQuery(io, gpa, from_file, positionals, stderr) orelse
        return .invalid_args;
    defer gpa.free(query);

    const gname = grammar_name orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        return .invalid_args;
    };

    const grammar = try grammars.get(gname, stderr) orelse
        return .invalid_args;

    var engine = try tql.Engine.init(.{ .allocator = gpa, .io = io });
    defer engine.deinit();
    var files: FileLoader = .{ .io = io, .gpa = gpa, .roots = module_roots };
    defer files.deinit();
    engine.loader = files.loader();

    var sink = tql.diagnostic.Sink.init(gpa);
    defer sink.deinit();

    var compiled = engine.compileQuery(query, grammar, &sink) catch |err| {
        try common.reportDiagnostics(&engine, &sink, query, from_file, stderr);
        if (!sink.hasErrors()) try stderr.print("Error: {}\n", .{err});
        return .compilation_error;
    };
    defer compiled.deinit();

    const printer = tql.stg.Printer{ .interner = &compiled.checked.env.interner };
    try printer.definitions(compiled.translated.definitions, stdout);
    try stdout.writeByte('\n');

    return .success;
}
