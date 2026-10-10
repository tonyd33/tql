const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const common = @import("common.zig");
const Context = common.Context;
const ExitCode = common.ExitCode;
const Opt = goz.Opt;
const printUsage = goz.printUsage;

pub const command = .{
    .name = "tql inspect",
    .description = "Show a file's tree or a grammar's kinds",
    .opts = .{
        .help = Opt{ .names = .{ .long = "help", .short = 'h' }, .description = "Show this help" },
        .grammar = Opt{ .names = .{ .long = "grammar", .short = 'g' }, .has_arg = .required_argument, .meta = "grammar", .description = "Grammar (required)" },
        .kind = Opt{ .names = .{ .long = "kind", .short = 'k' }, .has_arg = .required_argument, .meta = "kind", .description = "Show only this kind; repeatable" },
        .named = Opt{ .names = .{ .long = "named" }, .description = "Omit anonymous tokens" },
        .format = Opt{ .names = .{ .long = "format" }, .has_arg = .required_argument, .meta = "format", .description = "Output format: text, json (default: text)" },
    },
    .positionals = &[_]goz.Positional{
        .{ .name = "file", .required = false, .variadic = true },
    },
};

const InspectFormat = enum { text, json };

pub fn run(ctx: *const Context, iter: *std.process.Args.Iterator) !ExitCode {
    const io = ctx.io;
    const gpa = ctx.gpa;
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;

    var grammars = try common.Grammars.init(gpa, ctx.environ_map);
    defer grammars.deinit(gpa);

    var arg_diagnostic: goz.Diagnostic = .{};
    var tokenizer = goz.ArgTokenizer(command.opts).init(iter, &arg_diagnostic);

    var show_help = false;
    var grammar: ?*const tql.Grammar = null;
    var options: tql.inspect.Options = .{};
    var format: InspectFormat = .text;
    var kind_names: std.ArrayList([]const u8) = .empty;
    defer kind_names.deinit(gpa);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    while (tokenizer.next() catch |err| return common.reportArgError(stderr, err, arg_diagnostic)) |tok| {
        switch (tok) {
            .flag => |f| switch (f) {
                .help => show_help = true,
                .named => options.named_only = true,
            },
            .named_arg => |kv| switch (kv.field) {
                .grammar => grammar = try grammars.get(kv.value, stderr) orelse
                    return .invalid_args,
                .kind => try kind_names.append(gpa, kv.value),
                .format => format = std.meta.stringToEnum(InspectFormat, kv.value) orelse {
                    try stderr.print("Error: unknown format '{s}'\n", .{kv.value});
                    return .invalid_args;
                },
            },
            .positional => |p| try files.append(gpa, p),
        }
    }

    if (show_help) {
        try printUsage(command, stderr);
        return .success;
    }

    const language = (grammar orelse {
        try stderr.print("Error: --grammar is required\n", .{});
        try printUsage(command, stderr);
        return .invalid_args;
    }).language;

    var kinds: std.ArrayList(u16) = .empty;
    defer kinds.deinit(gpa);
    for (kind_names.items) |raw| {
        const name = if (std.mem.startsWith(u8, raw, ":")) raw[1..] else raw;
        const id = language.idForNodeKind(name, true);
        if (id == 0) {
            try stderr.print("error[unknown-kind]: `{s}` is not a node kind in this grammar\n", .{name});
            return .invalid_args;
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
        return .success;
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

    if (failed) return .runtime_error;
    return .success;
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
