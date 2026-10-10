const std = @import("std");
const goz = @import("goz");
const common = @import("common.zig");
const ExitCode = common.ExitCode;
const Opt = goz.Opt;
const printUsage = goz.printUsage;

const subcommands = .{
    .query = @import("query.zig"),
    .inspect = @import("inspect.zig"),
    .version = @import("version.zig"),
    .grammar = @import("grammar.zig"),
    .debug = @import("debug.zig"),
};

const main_opts = .{
    .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
};

const main_cmd = .{
    .name = "tql",
    .opts = main_opts,
    .subcmds = subcommands,
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

    const ctx: common.Context = .{
        .io = init.io,
        .gpa = init.gpa,
        .stdout = stdout,
        .stderr = stderr,
        .environ_map = init.environ_map,
    };
    return @intFromEnum(try dispatch(&ctx, &iter));
}

fn dispatch(ctx: *const common.Context, iter: *std.process.Args.Iterator) !ExitCode {
    const stderr = ctx.stderr;

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = goz.ArgTokenizer(main_opts).init(iter, &arg_diagnostic);
    var show_help = false;
    var subcmd: ?[]const u8 = null;

    while (tokenizer.next() catch |err| return common.reportArgError(stderr, err, arg_diagnostic)) |tok| {
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
        return .success;
    }

    const word = subcmd orelse {
        try printUsage(main_cmd, stderr);
        return .success;
    };

    switch (goz.SubcmdResolver(subcommands).match(word)) {
        .subcmd => |s| switch (s) {
            inline else => |tag| return @field(subcommands, @tagName(tag)).run(ctx, iter),
        },
        .unknown => |w| {
            try stderr.print("Error: unknown command '{s}'\n", .{w});
            try printUsage(main_cmd, stderr);
            return .invalid_args;
        },
    }
}

test {
    _ = subcommands;
    _ = @import("FileLoader.zig");
}
