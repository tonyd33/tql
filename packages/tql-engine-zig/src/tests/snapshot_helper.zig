const std = @import("std");
const testing = std.testing;
const ts = @import("tree-sitter");
const Compiler = @import("../compiler.zig").Compiler;
const Parser = @import("../parser.zig").Parser;
const runtime = @import("../runtime.zig");
const ast = @import("../ast.zig");
const query = @import("../query.zig");

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

/// Load snapshot from file, or return null if file doesn't exist
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

extern fn tree_sitter_typescript() *ts.Language;

/// Helper to create a test tree-sitter tree from TypeScript source
pub fn parseTypeScript(source: []const u8) !*ts.Tree {
    const language = tree_sitter_typescript();
    const parser = ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(language);
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;

    return tree;
}

pub fn SnapshotTester(allocator: std.mem.Allocator, group: []const u8) type {
    return struct {
        const Self = @This();
        tql: []const u8,
        source: []const u8,
        name: []const u8,
        update_snapshots: bool = false,

        pub fn run(self: Self) !void {
            const language = tree_sitter_typescript();

            var parser = try Parser.init(allocator);
            defer parser.deinit();

            var source_file = try parser.parse(self.tql);
            defer source_file.deinit(allocator);

            var compiler = Compiler.init(allocator, language);
            defer compiler.deinit();

            var program = try compiler.compile(allocator, source_file);
            defer program.deinit();

            const tree = try parseTypeScript(self.source);
            defer tree.destroy();

            var rt = runtime.Runtime.init(.{
                .tree = tree,
                .source = self.source,
                .instructions = program.instructions,
                .regexes = program.regexes,
                .allocator = allocator,
            });
            defer rt.deinit();

            try rt.exec();

            var values = std.ArrayList(query.Value){};
            defer {
                for (values.items) |*v| v.deinit(allocator);
                values.deinit(allocator);
            }

            while (try rt.nextMatch()) |value| {
                const enriched = try query.Value.fromRuntimeValue(allocator, value, self.source);
                try values.append(allocator, enriched);
            }

            const actual_ast = try source_file.sexprAlloc(allocator);
            defer allocator.free(actual_ast);

            const actual_bytecode = try renderBytecode(allocator, program.instructions);
            defer allocator.free(actual_bytecode);

            const actual_values = try renderValues(allocator, values.items);
            defer allocator.free(actual_values);

            const ast_path = try std.fmt.allocPrint(
                allocator,
                "src/tests/snapshots/{s}/{s}/ast.sexpr",
                .{ group, self.name },
            );
            defer allocator.free(ast_path);

            const bytecode_path = try std.fmt.allocPrint(
                allocator,
                "src/tests/snapshots/{s}/{s}/bytecode.txt",
                .{ group, self.name },
            );
            defer allocator.free(bytecode_path);

            const values_path = try std.fmt.allocPrint(
                allocator,
                "src/tests/snapshots/{s}/{s}/values.json",
                .{ group, self.name },
            );
            defer allocator.free(values_path);

            var any_failed = false;
            expectMatchesSnapshot(allocator, ast_path, actual_ast, self.update_snapshots) catch |err| {
                if (err != error.SnapshotMismatch) return err;
                any_failed = true;
            };
            expectMatchesSnapshot(allocator, bytecode_path, actual_bytecode, self.update_snapshots) catch |err| {
                if (err != error.SnapshotMismatch) return err;
                any_failed = true;
            };
            expectMatchesSnapshot(allocator, values_path, actual_values, self.update_snapshots) catch |err| {
                if (err != error.SnapshotMismatch) return err;
                any_failed = true;
            };
            if (any_failed) return error.SnapshotMismatch;
        }
    };
}

fn renderBytecode(gpa: std.mem.Allocator, instructions: []const runtime.Instruction) ![]const u8 {
    return try formatInstructions(gpa, instructions);
}

fn renderValues(gpa: std.mem.Allocator, values: []const query.Value) ![]const u8 {
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
