const std = @import("std");
const testing = std.testing;
const ts = @import("tree-sitter");
const Compiler = @import("../../compiler.zig").Compiler;
const Parser = @import("../../parser.zig").Parser;
const runtime = @import("../../runtime.zig");
const ast = @import("../../ast.zig");
const query = @import("../../query.zig");

pub fn formatInstructions(allocator: std.mem.Allocator, instructions: []const runtime.Instruction) ![]const u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    const writer = list.writer(allocator);
    for (instructions, 0..) |inst, i| {
        try writer.print("{d}: ", .{i});
        try formatInstruction(writer, inst);
        try writer.writeByte('\n');
    }

    return try list.toOwnedSlice(allocator);
}

fn formatInstruction(writer: anytype, inst: runtime.Instruction) !void {
    switch (inst) {
        .noop => try writer.writeAll("noop"),
        .yield => try writer.writeAll("yield"),
        .halt => |h| try writer.print("halt {s}", .{@tagName(h.condition)}),
        .trv => |t| {
            try writer.writeAll("trv ");
            switch (t) {
                .child => try writer.print("child", .{}),
                .descendant => try writer.print("descendant", .{}),
                .field => |f| try writer.print("field {}", .{f}),
                .variable_id => |v| try writer.print("variable_id {}", .{v}),
            }
        },
        .asn => |a| {
            try writer.print("asn {} (", .{a.variable_id});
            try formatValueSource(writer, a.source);
            try writer.writeAll(")");
        },
        .rel => |r| {
            try writer.print("rel {s} (", .{@tagName(r.relation)});
            try formatValueSource(writer, r.a);
            try writer.writeAll(") (");
            try formatValueSource(writer, r.b);
            try writer.writeAll(")");
        },
        .probe => |p| try writer.print("probe {s} {}", .{ @tagName(p.mode), p.on_success }),
        .call => |c| try writer.print("call {}", .{c}),
        .ret => try writer.writeAll("ret"),
        .jmp => |j| try writer.print("jmp {s} {}", .{ @tagName(j.mode), j.address }),
        .begin_build => |v| try writer.print("begin_build {s}", .{@tagName(v)}),
        .push_build => |i| {
            if (i.name) |name| {
                try writer.print("push_build {s} (", .{name});
            } else {
                try writer.writeAll("push_build (");
            }
            try formatValueSource(writer, i.source);
            try writer.writeAll(")");
        },
        .end_build => |v| try writer.print("end_build {}", .{v}),
        .panic => try writer.writeAll("panic"),
    }
}

fn formatValueSource(writer: anytype, source: runtime.ValueSource) !void {
    switch (source) {
        .literal => |l| {
            try writer.writeAll("literal ");
            switch (l) {
                .nothing => try writer.writeAll("nothing"),
                .string => |s| try writer.print("string \"{s}\"", .{s}),
                .kind_id => |k| try writer.print("kind_id {}", .{k}),
                .field_id => |f| try writer.print("field_id {}", .{f}),
                .range => try writer.writeAll("range ..."),
                .node => try writer.writeAll("node ..."),
                .regex => try writer.writeAll("regex ..."),
                .record => try writer.writeAll("record ..."),
                .list => try writer.writeAll("list ..."),
            }
        },
        .node => |n| try writer.print("node {s}", .{@tagName(n)}),
        .variable_id => |v| try writer.print("variable_id {}", .{v}),
    }
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

pub const SnapshotTest = struct {
    allocator: std.mem.Allocator,
    tql: []const u8,
    source: []const u8,
    snapshot_path: []const u8,
    update_snapshots: bool = false,

    pub fn run(self: SnapshotTest) !void {
        const language = tree_sitter_typescript();

        var parser = try Parser.init(self.allocator);
        defer parser.deinit();

        var source_file = try parser.parse(self.tql);
        defer source_file.deinit(self.allocator);

        var compiler = Compiler.init(self.allocator, language);
        defer compiler.deinit();

        var program = try compiler.compile(self.allocator, source_file);
        defer program.deinit();

        const tree = try parseTypeScript(self.source);
        defer tree.destroy();

        var rt = runtime.Runtime.init(.{
            .tree = tree,
            .source = self.source,
            .instructions = program.instructions,
            .regexes = program.regexes,
            .allocator = self.allocator,
        });
        defer rt.deinit();

        try rt.exec();

        var values = std.ArrayList(query.Value){};
        defer {
            for (values.items) |*v| v.deinit(self.allocator);
            values.deinit(self.allocator);
        }

        while (try rt.nextMatch()) |value| {
            const enriched = try query.Value.fromRuntimeValue(self.allocator, value, self.source);
            try values.append(self.allocator, enriched);
        }

        const actual = try renderSnapshot(self.allocator, program.instructions, values.items);
        defer self.allocator.free(actual);

        try expectMatchesSnapshot(self.allocator, self.snapshot_path, actual, self.update_snapshots);
    }
};

fn renderSnapshot(gpa: std.mem.Allocator, instructions: []const runtime.Instruction, values: []const query.Value) ![]const u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(gpa);
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    const writer = &w.writer;

    try writer.writeAll("=== bytecode ===\n");
    const bytecode = try formatInstructions(gpa, instructions);
    defer gpa.free(bytecode);
    try writer.writeAll(bytecode);

    try writer.writeAll("=== values ===\n");
    for (values) |v| {
        var jws = std.json.Stringify{ .writer = writer };
        try jws.write(v);
        try writer.writeByte('\n');
    }

    buf = w.toArrayList();
    return try buf.toOwnedSlice(gpa);
}
