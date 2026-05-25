const std = @import("std");
const ts = @import("tree-sitter");
const engine = @import("../engine.zig");
const runtime = @import("../runtime.zig");

const Compiler = @import("../compiler.zig").Compiler;
const Language = @import("../language.zig").Language;
const Parser = @import("../parser.zig").Parser;
const Runtime = @import("../runtime.zig").Runtime;

const Self = @This();

const test_options = @import("test_options");

pub const SnapshotQueryOpts = struct {
    query: []const u8,
    target: []const u8,
    language: Language = .typescript,
};

pub fn snapshotQuery(comptime src: std.builtin.SourceLocation, opts: SnapshotQueryOpts) !void {
    const group = comptime groupFromFile(src.file);
    const test_name = comptime sanitize(src.fn_name);
    const update_snapshots = test_options.update_snapshots;
    const allocator = std.testing.allocator;
    const language = opts.language.getTreeSitterLanguage();

    var tql_parser = try Parser.init(allocator);
    defer tql_parser.deinit();

    var ast = try tql_parser.parse(opts.query);
    defer ast.deinit(allocator);

    var compiler = Compiler.init(allocator, language);
    defer compiler.deinit();

    var program = try compiler.compile(allocator, ast);
    defer program.deinit();

    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(language);
    const tree = parser.parseString(opts.target, null) orelse return error.ParseFailed;
    defer tree.destroy();

    var rt = Runtime.init(.{
        .tree = tree,
        .source = opts.target,
        .instructions = program.instructions,
        .regexes = program.regexes,
        .allocator = allocator,
    });
    defer rt.deinit();

    try rt.exec();

    var values = std.ArrayList(engine.Value){};
    defer {
        for (values.items) |*v| v.deinit(allocator);
        values.deinit(allocator);
    }

    while (try rt.next()) |value| {
        const enriched = try engine.Value.fromRuntimeValue(allocator, value, opts.target);
        try values.append(allocator, enriched);
    }

    const actual_ast = try ast.sexprAlloc(allocator);
    defer allocator.free(actual_ast);

    const actual_bytecode = try renderBytecode(allocator, program.instructions);
    defer allocator.free(actual_bytecode);

    const actual_values = try renderValues(allocator, values.items);
    defer allocator.free(actual_values);

    const ast_path = try std.fmt.allocPrint(
        allocator,
        "src/tests/snapshots/{s}/{s}/ast.sexpr",
        .{ group, test_name },
    );
    defer allocator.free(ast_path);

    const bytecode_path = try std.fmt.allocPrint(
        allocator,
        "src/tests/snapshots/{s}/{s}/bytecode.txt",
        .{ group, test_name },
    );
    defer allocator.free(bytecode_path);

    const values_path = try std.fmt.allocPrint(
        allocator,
        "src/tests/snapshots/{s}/{s}/values.json",
        .{ group, test_name },
    );
    defer allocator.free(values_path);

    var any_failed = false;
    expectMatchesSnapshot(allocator, ast_path, actual_ast, update_snapshots) catch |err| {
        if (err != error.SnapshotMismatch) return err;
        any_failed = true;
    };
    expectMatchesSnapshot(allocator, bytecode_path, actual_bytecode, update_snapshots) catch |err| {
        if (err != error.SnapshotMismatch) return err;
        any_failed = true;
    };
    expectMatchesSnapshot(allocator, values_path, actual_values, update_snapshots) catch |err| {
        if (err != error.SnapshotMismatch) return err;
        any_failed = true;
    };
    if (any_failed) return error.SnapshotMismatch;
}

fn renderBytecode(gpa: std.mem.Allocator, instructions: []const runtime.Instruction) ![]const u8 {
    return try formatInstructions(gpa, instructions);
}

fn renderValues(gpa: std.mem.Allocator, values: []const engine.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    const writer = &w.writer;

    var jws = std.json.Stringify{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try jws.beginArray();
    for (values) |v| {
        try jws.write(v);
    }
    try jws.endArray();

    return try w.toOwnedSlice();
}

pub fn formatInstructions(allocator: std.mem.Allocator, instructions: []const runtime.Instruction) ![]const u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    // fuck this stupid interface
    const writer = list.writer(allocator);
    for (instructions, 0..) |inst, i| {
        try writer.print("{d:0>4}: ", .{i});
        try inst.print(&writer);
        try writer.writeByte('\n');
    }

    return try list.toOwnedSlice(allocator);
}

/// Load snapshot with file, or return null if file doesn't exist
pub fn loadSnapshot(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    return content;
}

/// Save snapshot to file
pub fn saveSnapshot(path: []const u8, content: []const u8) !void {
    // Ensure directory exists
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(content);
}

/// Compare actual output with snapshot, with option to update on mismatch
pub fn expectMatchesSnapshot(
    allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    actual: []const u8,
    update_on_mismatch: bool,
) !void {
    const expected = try loadSnapshot(allocator, snapshot_path);
    defer if (expected) |e| allocator.free(e);

    if (expected) |exp| {
        if (std.mem.eql(u8, exp, actual)) {
            // Snapshot matches!
            return;
        }

        if (update_on_mismatch) {
            // Update snapshot
            std.debug.print("Updating snapshot: {s}\n", .{snapshot_path});
            try saveSnapshot(snapshot_path, actual);
            return;
        }

        // Mismatch - show error
        std.debug.print("\nSnapshot mismatch: {s}\n", .{snapshot_path});
        std.debug.print("Expected:\n{s}\n", .{exp});
        std.debug.print("Actual:\n{s}\n", .{actual});
        return error.SnapshotMismatch;
    } else {
        // No snapshot exists - create it
        std.debug.print("Creating snapshot: {s}\n", .{snapshot_path});
        try saveSnapshot(snapshot_path, actual);
    }
}

fn groupFromFile(comptime path: []const u8) []const u8 {
    const basename = comptime blk: {
        var i: usize = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/' or path[i - 1] == '\\') break :blk path[i..];
        }
        break :blk path;
    };
    const stem = comptime if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;
    const suffix = "_tests";
    return comptime if (std.mem.endsWith(u8, stem, suffix)) stem[0 .. stem.len - suffix.len] else stem;
}

fn sanitize(comptime name: []const u8) []const u8 {
    const prefix = "test.";
    const stripped = comptime if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else name;
    comptime var out: [stripped.len]u8 = undefined;
    inline for (stripped, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => c,
            else => '_',
        };
    }
    const result = out;
    return &result;
}
