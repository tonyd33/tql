const std = @import("std");

const SEP = "================================================================================";
const SECTION_QUERY = "--- query ---";
const SECTION_SOURCE = "--- source ---";
const SECTION_SOURCE_AST = "--- source ast ---";
const SECTION_AST = "--- tql ast ---";
const SECTION_BYTECODE = "--- bytecode ---";
const SECTION_VALUES = "--- values ---";

pub const TestCase = struct {
    name: []const u8,
    grammar: []const u8,
    query: []const u8,
    target: []const u8,
    source_ast: ?[]const u8,
    expected_tql_ast: ?[]const u8,
    expected_bytecode: ?[]const u8,
    expected_values: ?[]const u8,

    pub fn deinit(self: *TestCase, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.grammar);
        allocator.free(self.query);
        allocator.free(self.target);
        if (self.source_ast) |s| allocator.free(s);
        if (self.expected_tql_ast) |s| allocator.free(s);
        if (self.expected_bytecode) |s| allocator.free(s);
        if (self.expected_values) |s| allocator.free(s);
    }
};

pub const CorpusFile = struct {
    cases: []TestCase,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CorpusFile) void {
        for (self.cases) |*c| c.deinit(self.allocator);
        self.allocator.free(self.cases);
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !CorpusFile {
    var cases: std.ArrayList(TestCase) = .empty;
    errdefer {
        for (cases.items) |*c| c.deinit(allocator);
        cases.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');

    while (true) {
        const line = lines.next() orelse break;
        if (!std.mem.eql(u8, line, SEP)) continue;

        const name_line = lines.next() orelse break;
        const sep2 = lines.next() orelse break;
        if (!std.mem.eql(u8, sep2, SEP)) continue;

        const grammar_line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, grammar_line, "grammar: ")) return error.MissingGrammar;
        const grammar = grammar_line["grammar: ".len..];

        const tc = try parseCase(allocator, &lines, name_line, grammar);
        try cases.append(allocator, tc);
    }

    return .{
        .cases = try cases.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseCase(
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    name: []const u8,
    grammar: []const u8,
) !TestCase {
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, SECTION_QUERY)) break;
    }
    const query = try extractSection(allocator, lines, SECTION_QUERY, SECTION_SOURCE);
    errdefer allocator.free(query);

    const target = try extractSection(allocator, lines, SECTION_SOURCE, SECTION_SOURCE_AST);
    errdefer allocator.free(target);

    const source_ast_raw = try extractSection(allocator, lines, SECTION_SOURCE_AST, SECTION_AST);
    errdefer allocator.free(source_ast_raw);
    const source_ast: ?[]const u8 = if (source_ast_raw.len == 0) blk: {
        allocator.free(source_ast_raw);
        break :blk null;
    } else source_ast_raw;

    const expected_tql_ast_raw = try extractSection(allocator, lines, SECTION_AST, SECTION_BYTECODE);
    errdefer allocator.free(expected_tql_ast_raw);
    const expected_tql_ast: ?[]const u8 = if (expected_tql_ast_raw.len == 0) blk: {
        allocator.free(expected_tql_ast_raw);
        break :blk null;
    } else expected_tql_ast_raw;

    const expected_bytecode_raw = try extractSection(allocator, lines, SECTION_BYTECODE, SECTION_VALUES);
    errdefer allocator.free(expected_bytecode_raw);
    const expected_bytecode: ?[]const u8 = if (expected_bytecode_raw.len == 0) blk: {
        allocator.free(expected_bytecode_raw);
        break :blk null;
    } else expected_bytecode_raw;

    const expected_values_raw = try extractUntilSepOrEof(allocator, lines);
    errdefer allocator.free(expected_values_raw);
    const expected_values: ?[]const u8 = if (expected_values_raw.len == 0) blk: {
        allocator.free(expected_values_raw);
        break :blk null;
    } else expected_values_raw;

    return .{
        .name = try allocator.dupe(u8, name),
        .grammar = try allocator.dupe(u8, grammar),
        .query = query,
        .target = target,
        .source_ast = source_ast,
        .expected_tql_ast = expected_tql_ast,
        .expected_bytecode = expected_bytecode,
        .expected_values = expected_values,
    };
}

const ALL_SECTIONS = [_][]const u8{
    SECTION_QUERY,
    SECTION_SOURCE,
    SECTION_SOURCE_AST,
    SECTION_AST,
    SECTION_BYTECODE,
    SECTION_VALUES,
    SEP,
};

fn isSectionMarker(line: []const u8) bool {
    for (ALL_SECTIONS) |marker| {
        if (std.mem.eql(u8, line, marker)) return true;
    }
    return false;
}

fn extractSection(
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
    start_marker: []const u8,
    end_marker: []const u8,
) ![]const u8 {
    _ = start_marker;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var first = true;
    while (lines.peek()) |line| {
        if (std.mem.eql(u8, line, end_marker)) {
            _ = lines.next();
            break;
        }
        if (isSectionMarker(line)) break;
        _ = lines.next();
        if (!first) try buf.append(allocator, '\n');
        first = false;
        try buf.appendSlice(allocator, line);
    }

    const raw = try buf.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, raw, "\n");
    if (trimmed.len == raw.len) return raw;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return result;
}

fn extractUntilSepOrEof(
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var first = true;
    while (lines.peek()) |line| {
        if (std.mem.eql(u8, line, SEP)) break;
        _ = lines.next();
        if (!first) try buf.append(allocator, '\n');
        first = false;
        try buf.appendSlice(allocator, line);
    }

    const raw = try buf.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, raw, "\n");
    if (trimmed.len == raw.len) return raw;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return result;
}

pub fn serialize(writer: *std.Io.Writer, cases: []const TestCase) !void {
    for (cases, 0..) |tc, i| {
        if (i > 0) try writer.writeByte('\n');
        try writer.writeAll(SEP ++ "\n");
        try writer.writeAll(tc.name);
        try writer.writeByte('\n');
        try writer.writeAll(SEP ++ "\n");
        try writer.print("grammar: {s}\n", .{tc.grammar});
        try writer.writeByte('\n');
        try writer.writeAll(SECTION_QUERY ++ "\n");
        try writer.writeAll(tc.query);
        try writer.writeByte('\n');
        try writer.writeAll(SECTION_SOURCE ++ "\n");
        try writer.writeAll(tc.target);
        try writer.writeByte('\n');
        try writer.writeAll(SECTION_SOURCE_AST ++ "\n");
        if (tc.source_ast) |s| {
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }
        try writer.writeAll(SECTION_AST ++ "\n");
        if (tc.expected_tql_ast) |s| {
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }
        try writer.writeAll(SECTION_BYTECODE ++ "\n");
        if (tc.expected_bytecode) |s| {
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }
        try writer.writeAll(SECTION_VALUES ++ "\n");
        if (tc.expected_values) |s| {
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }
    }
}
