const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const common = @import("common.zig");
const Context = common.Context;
const ExitCode = common.ExitCode;
const Opt = goz.Opt;
const printUsage = goz.printUsage;

const subcmds = .{
    .list = .{ .aliases = &[_][]const u8{"ls"}, .description = "List installed grammars" },
    .add = .{ .description = "Install grammars" },
    .remove = .{ .aliases = &[_][]const u8{"rm"}, .description = "Remove grammars" },
};

pub const command = .{
    .name = "tql grammar",
    .description = "Manage grammars",
    .opts = .{
        .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
        .install_dir = Opt{ .names = .{ .long = "install-dir" }, .has_arg = .required_argument, .meta = "dir", .description = "Grammar install directory" },
    },
    .subcmds = subcmds,
    .subcmd_label = "SUBCOMMAND",
    .positionals = &[_]goz.Positional{
        .{ .name = "grammar", .required = false, .variadic = true },
    },
};

pub fn run(ctx: *const Context, iter: *std.process.Args.Iterator) !ExitCode {
    const gpa = ctx.gpa;
    const stderr = ctx.stderr;

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = goz.ArgTokenizer(command.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var install_dir: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(gpa);

    while (tokenizer.next() catch |err| return common.reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
        try printUsage(command, stderr);
        return .success;
    }

    switch (goz.SubcmdResolver(subcmds).match(positionals.items[0])) {
        .subcmd => |s| switch (s) {
            .list => return list(ctx),
            .add => {}, // TODO: install grammars
            .remove => {}, // TODO: remove grammars
        },
        .unknown => |w| {
            try stderr.print("Error: unknown grammar subcommand '{s}'\n", .{w});
            try printUsage(command, stderr);
            return .invalid_args;
        },
    }

    return .success;
}

fn list(ctx: *const Context) !ExitCode {
    const gpa = ctx.gpa;
    const stderr = ctx.stderr;

    var grammars = try common.Grammars.init(gpa, ctx.environ_map);
    defer grammars.deinit(gpa);

    const dyn = try grammars.registry.listDynamic(ctx.io);
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

    return .success;
}
