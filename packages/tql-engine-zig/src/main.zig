const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const Engine = tql.Engine;
const Grammar = tql.Grammar;

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
            .include = Opt{ .names = .{ .long = "include", .short = 'I' }, .has_arg = .required_argument, .meta = "dir", .description = "Search dir for imported modules; repeatable" },
            .progress = Opt{ .names = .{ .long = "progress" }, .description = "Show progress" },
            .format = Opt{ .names = .{ .long = "format" }, .has_arg = .required_argument, .meta = "format", .description = "Output format: text, json (default: text)" },
        },
    },
    .inspect = .{
        .aliases = &[_][]const u8{},
        .description = @as(?[]const u8, "Show a file's tree or a grammar's kinds"),
        .opts = .{
            .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
            .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar (required)" },
            .kind = Opt{ .names = .{ .long = "kind", .short = 'k' }, .has_arg = .required_argument, .meta = "kind", .description = "Show only this kind; repeatable" },
            .named = Opt{ .names = .{ .long = "named" }, .description = "Omit anonymous tokens" },
            .format = Opt{ .names = .{ .long = "format" }, .has_arg = .required_argument, .meta = "format", .description = "Output format: text, json (default: text)" },
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
            .include = Opt{ .names = .{ .long = "include", .short = 'I' }, .has_arg = .required_argument, .meta = "dir", .description = "Search dir for imported modules; repeatable" },
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

const inspect_cmd = .{
    .name = "tql inspect",
    .opts = main_cmds.inspect.opts,
    .positionals = &[_]Positional{
        .{ .name = "file", .required = false, .variadic = true },
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

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = ArgTokenizer(main_opts).init(&iter, &arg_diagnostic);
    var show_help = false;
    var subcmd: ?[]const u8 = null;

    while (tokenizer.next() catch |err| return reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
            .inspect => return runInspect(
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
    var grammars = try Grammars.init(gpa, environ_map);
    defer grammars.deinit(gpa);

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = ArgTokenizer(main_cmds.query.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var from_file: ?[]const u8 = null;
    var workers: usize = 1;
    var grammar: ?*const Grammar = null;
    var progress = false;
    var format: OutputFormat = .text;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(gpa);
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
                        return @intFromEnum(ExitCode.invalid_args);
                    }
                },
                .grammar => grammar = try grammars.get(kv.value, stderr) orelse
                    return @intFromEnum(ExitCode.invalid_args),
                .format => format = std.meta.stringToEnum(OutputFormat, kv.value) orelse {
                    try stderr.print("Error: unknown format '{s}'\n", .{kv.value});
                    return @intFromEnum(ExitCode.invalid_args);
                },
                .include => try includes.append(gpa, kv.value),
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
    const query = try loadQuery(io, gpa, from_file, positionals.items, stderr) orelse {
        if (from_file == null) try printUsage(query_cmd, stderr);
        return @intFromEnum(ExitCode.invalid_args);
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

    const module_roots = try moduleRoots(gpa, from_file, includes.items, environ_map);
    defer gpa.free(module_roots);

    return run(gpa, io, stdout, stderr, .{
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
        return @intFromEnum(ExitCode.runtime_error);
    };
}

const InspectFormat = enum { text, json };

fn runInspect(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    iter: *std.process.Args.Iterator,
) !u8 {
    var grammars = try Grammars.init(gpa, environ_map);
    defer grammars.deinit(gpa);

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = ArgTokenizer(main_cmds.inspect.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var grammar: ?*const Grammar = null;
    var options: tql.inspect.Options = .{};
    var format: InspectFormat = .text;
    var kind_names: std.ArrayList([]const u8) = .empty;
    defer kind_names.deinit(gpa);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    while (tokenizer.next() catch |err| return reportArgError(stderr, err, arg_diagnostic)) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
                .named => options.named_only = true,
            },
            .named_arg => |kv| switch (kv.field) {
                .grammar => grammar = try grammars.get(kv.value, stderr) orelse
                    return @intFromEnum(ExitCode.invalid_args),
                .kind => try kind_names.append(gpa, kv.value),
                .format => format = std.meta.stringToEnum(InspectFormat, kv.value) orelse {
                    try stderr.print("Error: unknown format '{s}'\n", .{kv.value});
                    return @intFromEnum(ExitCode.invalid_args);
                },
            },
            .positional => |p| try files.append(gpa, p),
        }
    }

    if (show_help) {
        try printUsage(inspect_cmd, stderr);
        return @intFromEnum(ExitCode.success);
    }

    const language = (grammar orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        try printUsage(inspect_cmd, stderr);
        return @intFromEnum(ExitCode.invalid_args);
    }).language;

    var kinds: std.ArrayList(u16) = .empty;
    defer kinds.deinit(gpa);
    for (kind_names.items) |raw| {
        const name = if (std.mem.startsWith(u8, raw, ":")) raw[1..] else raw;
        const id = language.idForNodeKind(name, true);
        if (id == 0) {
            try stderr.print("error[unknown-kind]: `{s}` is not a node kind in this grammar\n", .{name});
            return @intFromEnum(ExitCode.invalid_args);
        }
        try kinds.append(gpa, id);
    }

    var jws: std.json.Stringify = .{ .writer = stdout };

    if (files.items.len == 0) {
        const ids = if (kinds.items.len > 0)
            try gpa.dupe(u16, kinds.items)
        else
            try tql.inspect.namedKinds(gpa, language);
        defer gpa.free(ids);

        switch (format) {
            .text => if (kinds.items.len == 0) {
                try tql.inspect.writeKindList(language, ids, stdout);
            } else for (ids, 0..) |id, i| {
                if (i > 0) try stdout.writeByte('\n');
                try tql.inspect.writeKind(language, id, stdout);
            },
            .json => {
                try jws.beginArray();
                for (ids) |id| try tql.inspect.writeKindJson(language, id, &jws);
                try jws.endArray();
                try stdout.writeByte('\n');
            },
        }
        return @intFromEnum(ExitCode.success);
    }

    const parser = tql.ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language);

    var target: InspectTarget = .{
        .io = io,
        .parser = parser,
        .kinds = kinds.items,
        .options = options,
        .format = format,
        .headed = files.items.len > 1,
        .stdout = stdout,
        .jws = &jws,
    };

    var failed = false;
    if (format == .json) try jws.beginArray();
    for (files.items) |path| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        target.inspect(arena.allocator(), path) catch |err| {
            failed = true;
            switch (format) {
                .text => {
                    try stderr.print("{s}: error: {t}\n", .{ path, err });
                    try stderr.flush();
                },
                .json => {
                    try jws.beginObject();
                    try jws.objectField("file");
                    try jws.write(path);
                    try jws.objectField("error");
                    try jws.write(@errorName(err));
                    try jws.endObject();
                },
            }
        };
    }
    if (format == .json) {
        try jws.endArray();
        try stdout.writeByte('\n');
    }

    if (failed) return @intFromEnum(ExitCode.runtime_error);
    return @intFromEnum(ExitCode.success);
}

const InspectTarget = struct {
    io: std.Io,
    parser: *tql.ts.Parser,
    kinds: []const u16,
    options: tql.inspect.Options,
    format: InspectFormat,
    headed: bool,
    stdout: *std.Io.Writer,
    jws: *std.json.Stringify,
    written: bool = false,

    fn inspect(self: *InspectTarget, arena: std.mem.Allocator, path: []const u8) !void {
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited);
        const tree = self.parser.parseString(source, null) orelse return error.SourceParseFailed;
        defer tree.destroy();

        var rows: std.ArrayList(tql.inspect.Row) = .empty;
        var starts: std.ArrayList(usize) = .empty;
        if (self.kinds.len == 0) {
            try starts.append(arena, 0);
            try tql.inspect.collect(arena, &rows, tree.rootNode(), source, self.options);
        } else {
            try tql.inspect.collectMatching(arena, &rows, &starts, tree.rootNode(), source, self.kinds, self.options);
        }

        switch (self.format) {
            .text => {
                const widths = tql.inspect.Widths.of(rows.items);
                for (starts.items, 0..) |start, i| {
                    const end = if (i + 1 < starts.items.len) starts.items[i + 1] else rows.items.len;
                    if (self.written) try self.stdout.writeByte('\n');
                    self.written = true;
                    if (self.kinds.len > 0) {
                        const p = rows.items[start].start_point;
                        try self.stdout.print("{s}:{d}:{d}\n", .{ path, p.row + 1, p.column + 1 });
                    } else if (self.headed) {
                        try self.stdout.print("{s}\n", .{path});
                    }
                    try tql.inspect.writeText(rows.items[start..end], widths, self.stdout);
                }
            },
            .json => {
                try self.jws.beginObject();
                try self.jws.objectField("file");
                try self.jws.write(path);
                try self.jws.objectField("nodes");
                if (self.kinds.len == 0) {
                    try tql.inspect.writeJson(rows.items, self.jws);
                } else {
                    try self.jws.beginArray();
                    for (starts.items, 0..) |start, i| {
                        const end = if (i + 1 < starts.items.len) starts.items[i + 1] else rows.items.len;
                        try tql.inspect.writeJson(rows.items[start..end], self.jws);
                    }
                    try self.jws.endArray();
                }
                try self.jws.endObject();
            },
        }
    }
};

fn runGrammar(
    io: std.Io,
    gpa: std.mem.Allocator,
    _: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    iter: *std.process.Args.Iterator,
) !u8 {
    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = ArgTokenizer(main_cmds.grammar.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var install_dir: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
    var grammars = try Grammars.init(gpa, environ_map);
    defer grammars.deinit(gpa);

    const dyn = try grammars.registry.listDynamic(io);
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
    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = ArgTokenizer(main_cmds.debug.opts).init(iter, &arg_diagnostic);

    var from_file: ?[]const u8 = null;
    var grammar_name: ?[]const u8 = null;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(gpa);
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
        return @intFromEnum(ExitCode.invalid_args);
    }

    switch (SubcmdResolver(debug_subcmds).match(positionals.items[0])) {
        .subcmd => |s| switch (s) {
            .@"dump-instructions" => {
                const module_roots = try moduleRoots(gpa, from_file, includes.items, environ_map);
                defer gpa.free(module_roots);
                return runDumpInstructions(io, gpa, stdout, stderr, environ_map, from_file, module_roots, grammar_name, positionals.items[1..]);
            },
        },
        .unknown => |w| {
            try stderr.print("Error: unknown debug subcommand '{s}'\n", .{w});
            return @intFromEnum(ExitCode.invalid_args);
        },
    }
}

/// Print the argument error and return the invalid-arguments exit code.
fn reportArgError(stderr: *std.Io.Writer, err: goz.ParseError, diag: goz.Diagnostic) !u8 {
    const line_end = std.mem.indexOfScalar(u8, diag.arg, '\n') orelse diag.arg.len;
    const arg = diag.arg[0..line_end];
    switch (err) {
        error.UnknownArg => try stderr.print("Error: unknown option '{s}'\n", .{arg}),
        error.MissingArg => try stderr.print("Error: option '{s}' requires a value\n", .{arg}),
        error.ExtraArg => try stderr.print("Error: option '{s}' takes no value\n", .{arg}),
        error.InvalidArgSyntax => try stderr.print("Error: malformed option '{s}'\n", .{arg}),
    }
    const looks_like_query = std.mem.startsWith(u8, diag.arg, "-- ") or line_end < diag.arg.len;
    if (err == error.UnknownArg and looks_like_query) {
        try stderr.writeAll("A query starting with a `--` comment must follow `--`, or be passed with -f.\n");
    }
    return @intFromEnum(ExitCode.invalid_args);
}

/// Where imports are searched, in order: the query file's directory, each
/// `-I` directory, then each directory in `TQL_PATH`. An inline query has no
/// directory of its own. The slices borrow from the arguments and `env`.
fn moduleRoots(
    gpa: std.mem.Allocator,
    query_path: ?[]const u8,
    includes: []const []const u8,
    env: *const std.process.Environ.Map,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer roots.deinit(gpa);
    if (query_path) |p| try roots.append(gpa, std.fs.path.dirname(p) orelse ".");
    try roots.appendSlice(gpa, includes);
    if (env.get("TQL_PATH")) |path| {
        var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
        while (it.next()) |part| {
            if (part.len > 0) try roots.append(gpa, part);
        }
    }
    return try roots.toOwnedSlice(gpa);
}

/// Serves module `A.B` from `A/B.tql` under the first root holding it.
const FileLoader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    roots: []const []const u8,
    /// Each file read, freed with the loader.
    read: std.ArrayList(tql.diagnostic.Source) = .empty,
    /// Why the latest load failed, if it did.
    failure: std.ArrayList(u8) = .empty,

    fn deinit(self: *FileLoader) void {
        for (self.read.items) |source| {
            self.gpa.free(source.name.?);
            self.gpa.free(source.text);
        }
        self.read.deinit(self.gpa);
        self.failure.deinit(self.gpa);
    }

    fn loader(self: *FileLoader) tql.Loader {
        return .{ .context = self, .loadFn = load };
    }

    fn load(context: *anyopaque, name: []const u8) tql.load.Loaded {
        const self: *FileLoader = @ptrCast(@alignCast(context));
        return self.find(name) catch |err| .{ .failed = @errorName(err) };
    }

    fn find(self: *FileLoader, name: []const u8) !tql.load.Loaded {
        const relative = try std.mem.concat(self.gpa, u8, &.{ name, ".tql" });
        defer self.gpa.free(relative);
        std.mem.replaceScalar(u8, relative[0..name.len], '.', std.fs.path.sep);

        for (self.roots) |root| {
            const path = try std.fs.path.join(self.gpa, &.{ root, relative });
            const text = readQueryFile(self.io, self.gpa, path) catch |err| {
                defer self.gpa.free(path);
                switch (err) {
                    // The root does not hold the module, or is not a directory.
                    error.FileNotFound, error.NotDir => continue,
                    else => {
                        self.failure.clearRetainingCapacity();
                        try self.failure.print(self.gpa, "`{s}`: {t}", .{ path, err });
                        return .{ .failed = self.failure.items };
                    },
                }
            };
            const source: tql.diagnostic.Source = .{ .name = path, .text = text };
            self.read.append(self.gpa, source) catch |err| {
                self.gpa.free(path);
                self.gpa.free(text);
                return err;
            };
            return .{ .found = source };
        }
        return .missing;
    }
};

fn readQueryFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
}

/// Returns the query, read from `from_file` or else taken from the first
/// positional, or null after reporting why there is none. The caller owns it.
fn loadQuery(
    io: std.Io,
    gpa: std.mem.Allocator,
    from_file: ?[]const u8,
    positionals: []const []const u8,
    stderr: *std.Io.Writer,
) !?[]u8 {
    if (from_file) |path| {
        return readQueryFile(io, gpa, path) catch |err| {
            try stderr.print("Error: cannot read query file '{s}': {t}\n", .{ path, err });
            return null;
        };
    }
    if (positionals.len == 0) {
        try stderr.print("Error: query is required\n", .{});
        return null;
    }
    return try gpa.dupe(u8, positionals[0]);
}

/// The grammar registry over the search paths the environment names.
const Grammars = struct {
    search_paths: []const []const u8,
    registry: tql.GrammarRegistry,

    fn init(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !Grammars {
        const search_paths = try tql.Grammar.resolveSearchPaths(gpa, environ_map);
        return .{ .search_paths = search_paths, .registry = tql.GrammarRegistry.init(gpa, search_paths) };
    }

    fn deinit(self: *Grammars, gpa: std.mem.Allocator) void {
        self.registry.deinit();
        for (self.search_paths) |p| gpa.free(p);
        gpa.free(self.search_paths);
    }

    /// Returns the grammar named `name`, or null after reporting that it was
    /// not found.
    fn get(self: *Grammars, name: []const u8, stderr: *std.Io.Writer) !?*const Grammar {
        return self.registry.get(name) catch |err| {
            try stderr.print("Error: grammar '{s}' not found: {t}\n", .{ name, err });
            return null;
        };
    }
};

/// Print every diagnostic a compilation collected, one per line, with the
/// source line it points at.
fn reportDiagnostics(
    engine: *const Engine,
    sink: *const tql.diagnostic.Sink,
    source: []const u8,
    path: ?[]const u8,
    stderr: *std.Io.Writer,
) !void {
    for (sink.items(), 0..) |d, i| {
        if (i > 0) try stderr.writeByte('\n');
        try d.render(stderr, engine.sourceOf(d.span.source, .{ .name = path, .text = source }));
    }
}

fn runDumpInstructions(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
    from_file: ?[]const u8,
    module_roots: []const []const u8,
    grammar_name: ?[]const u8,
    positionals: []const []const u8,
) !u8 {
    var grammars = try Grammars.init(gpa, environ_map);
    defer grammars.deinit(gpa);

    const query = try loadQuery(io, gpa, from_file, positionals, stderr) orelse
        return @intFromEnum(ExitCode.invalid_args);
    defer gpa.free(query);

    const gname = grammar_name orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        return @intFromEnum(ExitCode.invalid_args);
    };

    const grammar = try grammars.get(gname, stderr) orelse
        return @intFromEnum(ExitCode.invalid_args);

    var engine = try Engine.init(.{ .allocator = gpa, .io = io });
    defer engine.deinit();
    var files: FileLoader = .{ .io = io, .gpa = gpa, .roots = module_roots };
    defer files.deinit();
    engine.loader = files.loader();

    var sink = tql.diagnostic.Sink.init(gpa);
    defer sink.deinit();

    var compiled = engine.compileQuery(query, grammar, &sink) catch |err| {
        try reportDiagnostics(&engine, &sink, query, from_file, stderr);
        if (!sink.hasErrors()) try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.compilation_error);
    };
    defer compiled.deinit();

    const printer = tql.stg.Printer{ .interner = &compiled.checked.env.interner };
    try printer.definitions(compiled.translated.definitions, stdout);
    try stdout.writeByte('\n');

    return @intFromEnum(ExitCode.success);
}

const Config = struct {
    query: []const u8,
    /// The file `query` was read from, or null for an inline query.
    query_path: ?[]const u8,
    /// Where `import A.B` looks for `A/B.tql`, in order.
    module_roots: []const []const u8,
    query_target_paths: []const []const u8,
    format: OutputFormat,
    grammar: *const Grammar,
    workers: usize = 1,
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
};

const PathQueue = tql.ds.BlockingQueue(PathEntry);

const FileStats = struct {
    read_time: std.Io.Duration = .zero,
    parse_time: std.Io.Duration = .zero,
    query_time: std.Io.Duration = .zero,
};

fn writeStats(jws: *std.json.Stringify, stats: FileStats) !void {
    try jws.beginObject();
    try jws.objectField("read_time_ns");
    try jws.write(stats.read_time.nanoseconds);
    try jws.objectField("parse_time_ns");
    try jws.write(stats.parse_time.nanoseconds);
    try jws.objectField("query_time_ns");
    try jws.write(stats.query_time.nanoseconds);
    try jws.endObject();
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
};

const SharedContext = struct {
    compiled: *const tql.CompiledQuery,
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    result_queue: *ResultQueue,
    path_queue: *PathQueue,
    grammar: *const Grammar,
    progress: *Progress,
    io: std.Io,
    format: OutputFormat,
};

/// A fresh arena holding a copy of `path`.
fn ownPath(ctx: *SharedContext, path: []const u8) !PathEntry {
    const arena = try ctx.allocator.create(std.heap.ArenaAllocator);
    errdefer ctx.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(ctx.allocator);
    errdefer arena.deinit();
    return .{ .arena = arena, .path = try arena.allocator().dupe(u8, path) };
}

fn pushFile(ctx: *SharedContext, path: []const u8) !void {
    const entry = try ownPath(ctx, path);
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
fn pushFailure(ctx: *SharedContext, path: []const u8, err: anyerror) !void {
    const entry = try ownPath(ctx, path);
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

fn walkPush(ctx: *SharedContext, path: []const u8) !void {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, path, ctx.allocator);
    defer ctx.allocator.free(abs);
    var root_dir = try std.Io.Dir.openDirAbsolute(ctx.io, abs, .{
        .iterate = true,
    });
    defer root_dir.close(ctx.io);

    var walker = try root_dir.walk(ctx.allocator);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind == .file and ctx.*.grammar.matchesFileName(entry.basename)) {
            const joined = try std.fs.path.join(
                ctx.*.allocator,
                &[_][]const u8{ path, entry.path },
            );
            defer ctx.*.allocator.free(joined);
            try pushFile(ctx, joined);
        }
    }
}

fn walkerThread(ctx: *SharedContext) !void {
    // Workers wait on the path queue until it closes, so it closes however
    // the walk ends.
    defer ctx.path_queue.close() catch {};
    defer ctx.progress.done_walk.store(true, .release);

    for (ctx.paths) |path| {
        walkPush(ctx, path) catch |err| switch (err) {
            error.NotDir => try pushFile(ctx, path),
            else => try pushFailure(ctx, path, err),
        };
    }
}

fn writerThreadText(ctx: *SharedContext, stdout: *std.Io.Writer, stderr: *Stderr) !void {
    while (try ctx.result_queue.pop()) |result| {
        defer result.deinit();
        if (result.failure) |err| {
            try stderr.lock.lock(ctx.io);
            defer stderr.lock.unlock(ctx.io);
            try stderr.writer.print("{s}: error: {t}\n", .{ result.filename, err });
            try stderr.writer.flush();
            continue;
        }
        if (result.count == 0) continue;
        try stdout.print("{s}: {s}\n", .{ result.filename, result.values });
    }
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
            try jws.write(result.filename);
            try jws.objectField("error");
            try jws.write(@errorName(err));
            try jws.endObject();
            continue;
        }
        totals.read_time = std.Io.Duration.fromNanoseconds(totals.read_time.nanoseconds + result.stats.read_time.nanoseconds);
        totals.parse_time = std.Io.Duration.fromNanoseconds(totals.parse_time.nanoseconds + result.stats.parse_time.nanoseconds);
        totals.query_time = std.Io.Duration.fromNanoseconds(totals.query_time.nanoseconds + result.stats.query_time.nanoseconds);
        try jws.beginObject();
        try jws.objectField("file");
        try jws.write(result.filename);
        try jws.objectField("values");
        try jws.beginWriteRaw();
        try jws.writer.writeAll(result.values);
        jws.endWriteRaw();
        try jws.objectField("stats");
        try writeStats(jws, result.stats);
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("stats");
    try writeStats(jws, totals);
    try jws.endObject();
}

/// How much of one file's scratch a worker keeps for the next. A file that
/// needed more has the excess released instead of held for the rest of the run.
const worker_scratch_retained = 64 * 1024 * 1024;

fn workerThread(ctx: *SharedContext) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.*.allocator);
    defer arena.deinit();

    while (try ctx.path_queue.pop()) |entry| {
        defer {
            _ = arena.reset(.{ .retain_with_limit = worker_scratch_retained });
            _ = ctx.progress.done.fetchAdd(1, .monotonic);
        }

        // A file that cannot be read or run is reported and skipped.
        const result = queryFile(ctx, entry, arena.allocator()) catch |err|
            failedResult(ctx, entry, err);
        if (result.count > 0) _ = ctx.progress.matched.fetchAdd(1, .monotonic);

        ctx.result_queue.push(result) catch |err| {
            result.deinit();
            return err;
        };
    }
}

/// Read and run one target, rendering its outputs into the entry's arena.
fn queryFile(ctx: *SharedContext, entry: PathEntry, scratch: std.mem.Allocator) !FileResult {
    const read_start = std.Io.Timestamp.now(ctx.io, .real);
    const query_target: []align(std.heap.page_size_min) const u8 = blk: {
        const file = try std.Io.Dir.cwd().openFile(ctx.io, entry.path, .{});
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

    const run_result = try ctx.compiled.run(
        query_target,
        entry.path,
        entry.arena.allocator(),
        scratch,
    );

    return .{
        .arena = entry.arena,
        .gpa = ctx.allocator,
        .filename = entry.path,
        .values = run_result.json,
        .count = run_result.count,
        .stats = .{
            .read_time = read_time,
            .parse_time = run_result.parse_time,
            .query_time = run_result.query_time,
        },
    };
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
    var files: FileLoader = .{ .io = io, .gpa = allocator, .roots = config.module_roots };
    defer files.deinit();
    engine.loader = files.loader();

    var sink = tql.diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var compiled = engine.compileQuery(config.query, config.grammar, &sink) catch |err| {
        try reportDiagnostics(&engine, &sink, config.query, config.query_path, stderr);
        if (!sink.hasErrors()) try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.compilation_error);
    };
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

    if (progress.failed.load(.monotonic) > 0) return @intFromEnum(ExitCode.runtime_error);
    return @intFromEnum(ExitCode.success);
}

test "imports search the query's directory, then -I, then TQL_PATH" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("TQL_PATH", "/env/a::/env/b");

    const roots = try moduleRoots(gpa, "rules/q.tql", &.{ "lib", "vendor" }, &env);
    defer gpa.free(roots);
    try std.testing.expectEqual(5, roots.len);
    for ([_][]const u8{ "rules", "lib", "vendor", "/env/a", "/env/b" }, roots) |expected, root| {
        try std.testing.expectEqualStrings(expected, root);
    }
}

test "an inline query searches only -I and TQL_PATH" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const roots = try moduleRoots(gpa, null, &.{"lib"}, &env);
    defer gpa.free(roots);
    try std.testing.expectEqual(1, roots.len);
    try std.testing.expectEqualStrings("lib", roots[0]);
}
