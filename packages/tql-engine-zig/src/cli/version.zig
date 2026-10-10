const std = @import("std");
const tql = @import("tql");
const common = @import("common.zig");
const Context = common.Context;
const ExitCode = common.ExitCode;

pub const command = .{
    .name = "tql version",
    .description = "Get version info",
    .opts = .{},
};

pub fn run(ctx: *const Context, _: *std.process.Args.Iterator) !ExitCode {
    try ctx.stdout.print("tql version {s}\n", .{tql.VERSION});
    return .success;
}
