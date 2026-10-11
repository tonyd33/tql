const std = @import("std");
const tql = @import("tql");
const goz = @import("goz");
const FileLoader = @import("FileLoader.zig");

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environ_map: *const std.process.Environ.Map,
};

pub const ExitCode = enum(u8) {
    success = 0,
    parse_error = 2,
    compilation_error = 3,
    runtime_error = 4,
    invalid_args = 5,
};

/// Print the argument error and return the invalid-arguments exit code.
pub fn reportArgError(stderr: *std.Io.Writer, err: goz.ParseError, diag: goz.Diagnostic) !ExitCode {
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
    return .invalid_args;
}

/// Returns the query, read from `from_file` or else taken from the first
/// positional, or null after reporting why there is none. The caller owns it.
pub fn loadQuery(
    io: std.Io,
    gpa: std.mem.Allocator,
    from_file: ?[]const u8,
    positionals: []const []const u8,
    stderr: *std.Io.Writer,
) !?[]u8 {
    if (from_file) |path| {
        return FileLoader.readQueryFile(io, gpa, path) catch |err| {
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
pub const Grammars = struct {
    search_paths: []const []const u8,
    registry: tql.GrammarRegistry,

    pub fn init(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !Grammars {
        const search_paths = try tql.Grammar.resolveSearchPaths(gpa, environ_map);
        return .{ .search_paths = search_paths, .registry = tql.GrammarRegistry.init(gpa, search_paths) };
    }

    pub fn deinit(self: *Grammars, gpa: std.mem.Allocator) void {
        self.registry.deinit();
        for (self.search_paths) |p| gpa.free(p);
        gpa.free(self.search_paths);
    }

    /// Returns the grammar named `name`, or null after reporting that it was
    /// not found.
    pub fn get(self: *Grammars, name: []const u8, stderr: *std.Io.Writer) !?*const tql.Grammar {
        return self.registry.get(name) catch |err| {
            try stderr.print("Error: grammar '{s}' not found: {t}\n", .{ name, err });
            return null;
        };
    }
};

/// Print every diagnostic a compilation collected, one per line, with the
/// source line it points at.
pub fn reportDiagnostics(
    engine: *const tql.Engine,
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

/// Why a target failed, written for a user.
pub const TargetFailure = struct {
    err: anyerror,

    pub fn format(self: TargetFailure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (self.err) {
            error.FileNotFound => "no such file or directory",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            else => return tql.Failure.format(.{ .err = self.err }, w),
        });
    }
};
