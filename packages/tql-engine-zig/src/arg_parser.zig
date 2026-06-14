const std = @import("std");

const ArgToken = union(enum) {
    flag: []const u8, // field
    named_arg: struct {
        field: []const u8,
        value: []const u8,
    },
    named_arg_optional: struct {
        field: []const u8,
        value: ?[]const u8,
    },
    positional: []const u8,
};

const ParseError = error{
    MissingArg,
    ExtraArg,
    UnknownArg,
    InvalidArgSyntax,
};

const OptDef = struct {
    field: []const u8,
    names: struct { long: ?[]const u8 = null, short: ?u8 = null },
    has_arg: enum {
        no_argument,
        required_argument,
        optional_argument,
    } = .no_argument,
};

// TODO: optional args, nargs
fn Lexer(comptime _: type) type {
    return struct {
        const Self = @This();

        opt_defs: []const OptDef,
        iter: *std.process.Args.Iterator,
        continuation: ?[]const u8,

        pub fn init(
            iter: *std.process.Args.Iterator,
            comptime opt_defs: []const OptDef,
        ) Self {
            return .{
                .opt_defs = opt_defs,
                .iter = iter,
                .continuation = null,
            };
        }

        fn parseShort(self: *Self, rest: []const u8) !?ArgToken {
            const value = rest[0];
            // TODO: value should be a printable character except space (isgraph)
            for (self.opt_defs) |opt_def| {
                if (opt_def.names.short) |short| {
                    if (value != short) continue;

                    switch (opt_def.has_arg) {
                        .no_argument => {
                            if (rest.len > 1) {
                                self.continuation = rest[1..];
                            } else {
                                self.continuation = null;
                            }
                            return .{ .flag = opt_def.field };
                        },
                        .optional_argument => {
                            // we'll likely have to do something hacky by peeking into the iterator
                            @panic("crap");
                        },
                        .required_argument => {
                            if (rest.len > 1) {
                                if (rest[1] == '=') {
                                    if (rest.len == 2) {
                                        // no more chars, this is malformed
                                        return error.InvalidArgSyntax;
                                    } else {
                                        self.continuation = null;
                                        return .{ .named_arg = .{ .field = opt_def.field, .value = rest[2..] } };
                                    }
                                } else {
                                    self.continuation = null;
                                    return .{ .named_arg = .{ .field = opt_def.field, .value = rest[1..] } };
                                }
                            } else {
                                self.continuation = null;
                                const short_arg = self.iter.next() orelse return error.MissingArg;
                                return .{ .named_arg = .{ .field = opt_def.field, .value = short_arg } };
                            }
                        },
                    }
                }
            }
            return error.UnknownArg;
        }

        pub fn next(self: *Self) !?ArgToken {
            if (self.continuation) |continuation| {
                return try self.parseShort(continuation);
            } else if (self.iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "--")) return null;

                if (std.mem.startsWith(u8, arg, "--")) {
                    const rest = arg[2..];

                    for (self.opt_defs) |opt_def| {
                        if (opt_def.names.long) |long| {
                            if (!std.mem.startsWith(u8, rest, long)) continue;

                            switch (opt_def.has_arg) {
                                .no_argument => {
                                    if (rest.len == long.len) {
                                        return .{ .flag = opt_def.field };
                                    } else if (rest[long.len] == '=') {
                                        return error.ExtraArg;
                                    }
                                },
                                .optional_argument => {
                                    @panic("crap");
                                },
                                .required_argument => {
                                    if (rest.len > long.len) {
                                        if (rest[long.len] == '=') {
                                            if (rest.len == long.len + 1) {
                                                // no more chars, this is malformed
                                                return error.InvalidArgSyntax;
                                            } else {
                                                const long_arg = rest[long.len + 1 ..];
                                                return .{ .named_arg = .{ .field = opt_def.field, .value = long_arg } };
                                            }
                                        } else {
                                            // Possibly still recoverable, there may be another opt def
                                            // capable of parsing this.
                                            continue;
                                        }
                                    } else {
                                        const long_arg = self.iter.next() orelse return error.MissingArg;
                                        return .{ .named_arg = .{ .field = opt_def.field, .value = long_arg } };
                                    }
                                },
                            }
                        }
                    }
                    return error.UnknownArg;
                }

                if (arg.len > 1 and arg[0] == '-') {
                    const rest = arg[1..];
                    return self.parseShort(rest);
                }

                return .{ .positional = arg };
            } else {
                return null;
            }
        }
    };
}

const testing = std.testing;

test "tokenize" {
    const args = std.process.Args{ .vector = &.{
        "-a",
        "--alpha",
        "-bfoo",
        "--bravo", "foo",
        "hello",
        "-c",
        "bar",
        "--charlie=bar",
        "-def",
        "world",
    } };
    var iterator = args.iterate();
    var tokenizer = Lexer(u8).init(
        &iterator,
        &[_]OptDef{
            .{ .field = "a", .names = .{ .short = 'a' } },
            .{ .field = "b", .names = .{ .short = 'b' }, .has_arg = .required_argument },
            .{ .field = "c", .names = .{ .short = 'c' }, .has_arg = .required_argument },
            .{ .field = "d", .names = .{ .short = 'd' } },
            .{ .field = "e", .names = .{ .short = 'e' } },
            .{ .field = "f", .names = .{ .short = 'f' } },
            .{ .field = "alpha", .names = .{ .long = "alpha" } },
            .{ .field = "bravo", .names = .{ .long = "bravo" }, .has_arg = .required_argument },
            .{ .field = "charlie", .names = .{ .long = "charlie" }, .has_arg = .required_argument },
        },
    );
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .flag = "a" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .flag = "alpha" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .named_arg = .{ .field = "b", .value = "foo" } });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .named_arg = .{ .field = "bravo", .value = "foo" } });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .positional = "hello" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .named_arg = .{ .field = "c", .value = "bar" } });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .named_arg = .{ .field = "charlie", .value = "bar" } });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .flag = "d" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .flag = "e" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .flag = "f" });
    try testing.expectEqualDeep(tokenizer.next(), ArgToken{ .positional = "world" });
    try testing.expectEqualDeep(tokenizer.next(), null);

    iterator.deinit();
}
