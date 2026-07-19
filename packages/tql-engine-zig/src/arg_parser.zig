const std = @import("std");

pub const Opt = struct {
    names: struct { long: ?[]const u8 = null, short: ?u8 = null },
    has_arg: enum {
        no_argument,
        required_argument,
    } = .no_argument,
    meta: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const Positional = struct {
    name: []const u8,
    required: bool = false,
    variadic: bool = false,
};

fn writePositional(p: Positional, writer: *std.Io.Writer) !void {
    if (p.required) {
        try writer.print("<{s}>", .{p.name});
        if (p.variadic) try writer.writeAll("...");
    } else {
        try writer.print("[<{s}>", .{p.name});
        if (p.variadic) try writer.writeAll("...");
        try writer.writeAll("]");
    }
}

pub fn printUsage(comptime cmd: anytype, writer: *std.Io.Writer) !void {
    const name = cmd.name;
    const opts = cmd.opts;
    const has_subcmds = @hasField(@TypeOf(cmd), "subcmds");
    const has_positionals = @hasField(@TypeOf(cmd), "positionals");
    const subcmd_label = if (@hasField(@TypeOf(cmd), "subcmd_label")) cmd.subcmd_label else "COMMAND";

    try writer.print("Usage: {s}", .{name});
    if (has_subcmds) {
        try writer.print(" <{s}>", .{subcmd_label});
    }
    try writer.writeAll(" [OPTIONS]");
    if (has_positionals) {
        for (cmd.positionals) |p| {
            try writer.writeAll(" ");
            try writePositional(p, writer);
        }
    }
    try writer.writeAll("\n");

    if (has_subcmds) {
        try writer.writeAll("\n");
        if (std.mem.eql(u8, subcmd_label, "SUBCOMMAND")) {
            try writer.writeAll("Subcommands:\n");
        } else {
            try writer.writeAll("Commands:\n");
        }
        try printSubcmds(cmd.subcmds, writer);
    }

    try writer.writeAll("\nOptions:\n");
    try printHelp(opts, writer);
}

pub const ParseError = error{
    MissingArg,
    ExtraArg,
    UnknownArg,
    InvalidArgSyntax,
};

fn flagsStr(
    comptime short: ?u8,
    comptime long: ?[]const u8,
    comptime has_arg: anytype,
    comptime meta: ?[]const u8,
) []const u8 {
    comptime {
        var buf: [256]u8 = undefined;
        var i: usize = 0;
        if (short) |s| {
            buf[i] = '-';
            buf[i + 1] = s;
            i += 2;
        } else {
            buf[i] = ' ';
            buf[i + 1] = ' ';
            buf[i + 2] = ' ';
            buf[i + 3] = ' ';
            i += 4;
        }
        if (short != null and long != null) {
            buf[i] = ',';
            buf[i + 1] = ' ';
            i += 2;
        }
        if (long) |l| {
            buf[i] = '-';
            buf[i + 1] = '-';
            i += 2;
            for (l) |c| {
                buf[i] = c;
                i += 1;
            }
        }
        if (has_arg == .required_argument) {
            if (meta) |m| {
                buf[i] = ' ';
                buf[i + 1] = '<';
                i += 2;
                for (m) |c| {
                    buf[i] = c;
                    i += 1;
                }
                buf[i] = '>';
                i += 1;
            }
        }
        const result = buf[0..i].*;
        return &result;
    }
}

pub fn printHelp(comptime opts: anytype, writer: *std.Io.Writer) !void {
    const T = @TypeOf(opts);
    const col_width = comptime blk: {
        var w: usize = 0;
        for (std.meta.fields(T)) |f| {
            const opt: Opt = @field(opts, f.name);
            if (opt.description == null) continue;
            const fw = flagsStr(opt.names.short, opt.names.long, opt.has_arg, opt.meta).len;
            if (fw > w) w = fw;
        }
        break :blk w;
    };

    inline for (std.meta.fields(T)) |f| {
        const opt: Opt = @field(opts, f.name);
        if (opt.description) |desc| {
            const flags = comptime flagsStr(opt.names.short, opt.names.long, opt.has_arg, opt.meta);
            const w = flags.len;
            const pad = comptime " " ** (col_width + 2 - w);
            try writer.print("  {s}{s}{s}\n", .{ flags, pad, desc });
        }
    }
}

pub fn SubcmdResolver(comptime cmds: anytype) type {
    const T = @TypeOf(cmds);
    const Fields = std.meta.FieldEnum(T);

    return struct {
        pub const Result = union(enum) {
            subcmd: Fields,
            unknown: []const u8,
        };

        pub fn match(word: []const u8) Result {
            inline for (std.meta.fields(T)) |f| {
                if (std.mem.eql(u8, word, f.name)) return .{ .subcmd = @field(Fields, f.name) };
                const entry = @field(cmds, f.name);
                for (entry.aliases) |alias| {
                    if (std.mem.eql(u8, word, alias)) return .{ .subcmd = @field(Fields, f.name) };
                }
            }
            return .{ .unknown = word };
        }
    };
}

fn subcmdNamesStr(comptime aliases: []const []const u8, comptime name: []const u8) []const u8 {
    comptime {
        var buf: [256]u8 = undefined;
        var i: usize = 0;
        for (name) |c| {
            buf[i] = c;
            i += 1;
        }
        for (aliases) |a| {
            buf[i] = ',';
            buf[i + 1] = ' ';
            i += 2;
            for (a) |c| {
                buf[i] = c;
                i += 1;
            }
        }
        const result = buf[0..i].*;
        return &result;
    }
}

pub fn printSubcmds(comptime cmds: anytype, writer: *std.Io.Writer) !void {
    const T = @TypeOf(cmds);
    const col_width = comptime blk: {
        var w: usize = 0;
        for (std.meta.fields(T)) |f| {
            const entry = @field(cmds, f.name);
            const fw = subcmdNamesStr(entry.aliases, f.name).len;
            if (fw > w) w = fw;
        }
        break :blk w;
    };

    inline for (std.meta.fields(T)) |f| {
        const entry = @field(cmds, f.name);
        if (@hasField(@TypeOf(entry), "hidden") and entry.hidden) continue;
        const names = comptime subcmdNamesStr(entry.aliases, f.name);
        const w = names.len;
        const pad = comptime " " ** (col_width + 2 - w);
        if (entry.description) |desc| {
            try writer.print("  {s}{s}{s}\n", .{ names, pad, desc });
        } else {
            try writer.print("  {s}\n", .{names});
        }
    }
}

pub fn ArgTokenizer(comptime opts: anytype) type {
    const T = @TypeOf(opts);

    const flag_count = comptime blk: {
        var n: usize = 0;
        for (std.meta.fields(T)) |f| {
            const opt: Opt = @field(opts, f.name);
            if (opt.has_arg == .no_argument) n += 1;
        }
        break :blk n;
    };

    const arg_count = comptime blk: {
        var n: usize = 0;
        for (std.meta.fields(T)) |f| {
            const opt: Opt = @field(opts, f.name);
            if (opt.has_arg == .required_argument) n += 1;
        }
        break :blk n;
    };

    const FlagFields = blk: {
        var names: [flag_count][]const u8 = undefined;
        var vals: [flag_count]u16 = undefined;
        var i: usize = 0;
        for (std.meta.fields(T)) |f| {
            const opt: Opt = @field(opts, f.name);
            if (opt.has_arg == .no_argument) {
                names[i] = f.name;
                vals[i] = i;
                i += 1;
            }
        }
        break :blk @Enum(u16, .exhaustive, &names, &vals);
    };

    const ArgFields = blk: {
        var names: [arg_count][]const u8 = undefined;
        var vals: [arg_count]u16 = undefined;
        var i: usize = 0;
        for (std.meta.fields(T)) |f| {
            const opt: Opt = @field(opts, f.name);
            if (opt.has_arg == .required_argument) {
                names[i] = f.name;
                vals[i] = i;
                i += 1;
            }
        }
        break :blk @Enum(u16, .exhaustive, &names, &vals);
    };

    return struct {
        const Self = @This();

        pub const Token = union(enum) {
            flag: FlagFields,
            named_arg: struct { field: ArgFields, value: []const u8 },
            positional: []const u8,
        };

        iter: *std.process.Args.Iterator,
        continuation: ?[]const u8,

        pub fn init(iter: *std.process.Args.Iterator) Self {
            return .{ .iter = iter, .continuation = null };
        }

        fn parseShort(self: *Self, rest: []const u8) !?Token {
            const ch = rest[0];
            inline for (std.meta.fields(T)) |f| {
                const opt: Opt = @field(opts, f.name);
                if (opt.names.short) |short| {
                    if (ch == short) {
                        switch (opt.has_arg) {
                            .no_argument => {
                                self.continuation = if (rest.len > 1) rest[1..] else null;
                                return .{ .flag = @field(FlagFields, f.name) };
                            },
                            .required_argument => {
                                const field = @field(ArgFields, f.name);
                                if (rest.len > 1) {
                                    if (rest[1] == '=') {
                                        if (rest.len == 2) return error.InvalidArgSyntax;
                                        self.continuation = null;
                                        return .{ .named_arg = .{ .field = field, .value = rest[2..] } };
                                    } else {
                                        self.continuation = null;
                                        return .{ .named_arg = .{ .field = field, .value = rest[1..] } };
                                    }
                                } else {
                                    self.continuation = null;
                                    const val = self.iter.next() orelse return error.MissingArg;
                                    return .{ .named_arg = .{ .field = field, .value = val } };
                                }
                            },
                        }
                    }
                }
            }
            return error.UnknownArg;
        }

        pub fn next(self: *Self) !?Token {
            if (self.continuation) |cont| {
                return try self.parseShort(cont);
            }

            const arg = self.iter.next() orelse return null;

            if (std.mem.eql(u8, arg, "--")) return null;

            if (std.mem.startsWith(u8, arg, "--")) {
                const rest = arg[2..];
                inline for (std.meta.fields(T)) |f| {
                    const opt: Opt = @field(opts, f.name);
                    if (opt.names.long) |long| {
                        if (std.mem.startsWith(u8, rest, long)) {
                            switch (opt.has_arg) {
                                .no_argument => {
                                    if (rest.len == long.len) {
                                        return .{ .flag = @field(FlagFields, f.name) };
                                    } else if (rest[long.len] == '=') {
                                        return error.ExtraArg;
                                    }
                                },
                                .required_argument => {
                                    const field = @field(ArgFields, f.name);
                                    if (rest.len > long.len) {
                                        if (rest[long.len] == '=') {
                                            if (rest.len == long.len + 1) return error.InvalidArgSyntax;
                                            return .{ .named_arg = .{ .field = field, .value = rest[long.len + 1 ..] } };
                                        }
                                    } else {
                                        const val = self.iter.next() orelse return error.MissingArg;
                                        return .{ .named_arg = .{ .field = field, .value = val } };
                                    }
                                },
                            }
                        }
                    }
                }
                return error.UnknownArg;
            }

            if (arg.len > 1 and arg[0] == '-') {
                return self.parseShort(arg[1..]);
            }

            return .{ .positional = arg };
        }
    };
}

const testing = std.testing;

test "tokenize" {
    const opts = .{
        .a = Opt{ .names = .{ .short = 'a' } },
        .b = Opt{ .names = .{ .short = 'b' }, .has_arg = .required_argument },
        .c = Opt{ .names = .{ .short = 'c' }, .has_arg = .required_argument },
        .d = Opt{ .names = .{ .short = 'd' } },
        .e = Opt{ .names = .{ .short = 'e' } },
        .f = Opt{ .names = .{ .short = 'f' } },
        .alpha = Opt{ .names = .{ .long = "alpha" } },
        .bravo = Opt{ .names = .{ .long = "bravo" }, .has_arg = .required_argument },
        .charlie = Opt{ .names = .{ .long = "charlie" }, .has_arg = .required_argument },
    };

    const args = std.process.Args{ .vector = &.{
        "-a",
        "--alpha",
        "-bfoo",
        "--bravo",
        "foo",
        "hello",
        "-c",
        "bar",
        "--charlie=bar",
        "-def",
        "world",
    } };
    var iterator = args.iterate();
    var tokenizer = ArgTokenizer(opts).init(&iterator);

    const T = @TypeOf(tokenizer).Token;
    try testing.expectEqualDeep(try tokenizer.next(), T{ .flag = .a });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .flag = .alpha });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .named_arg = .{ .field = .b, .value = "foo" } });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .named_arg = .{ .field = .bravo, .value = "foo" } });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .positional = "hello" });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .named_arg = .{ .field = .c, .value = "bar" } });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .named_arg = .{ .field = .charlie, .value = "bar" } });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .flag = .d });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .flag = .e });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .flag = .f });
    try testing.expectEqualDeep(try tokenizer.next(), T{ .positional = "world" });
    try testing.expectEqualDeep(try tokenizer.next(), null);

    iterator.deinit();
}
