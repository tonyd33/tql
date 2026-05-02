const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const pcre2 = @import("../../pcre2.zig");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Match = types.Match;

const Runtime = @import("../core.zig").Runtime;

extern fn tree_sitter_c() callconv(.c) *ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *ts.Language;

pub const TestContext = struct {
    allocator: Allocator,
    language: *ts.Language,
    parser: *ts.Parser,
    tree: *ts.Tree,
    runtime: Runtime,

    pub fn init(x: struct {
        source: []const u8,
        instructions: []const Instruction,
        language: ?*ts.Language = null,
        allocator: ?Allocator = null,
    }) !TestContext {
        const allocator = x.allocator orelse std.testing.allocator;
        const language = x.language orelse tree_sitter_c();
        errdefer language.destroy();

        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);

        const tree = parser.parseString(x.source, null) orelse return error.ParseFailed;
        errdefer tree.destroy();

        const runtime = Runtime.init(.{
            .tree = tree,
            .source = x.source,
            .instructions = x.instructions,
            .regexes = &[_]pcre2.Regex{},
            .data = &[_]u8{},
            .allocator = allocator,
        });

        return TestContext{
            .allocator = allocator,
            .language = language,
            .parser = parser,
            .tree = tree,
            .runtime = runtime,
        };
    }

    pub fn deinit(self: *TestContext) void {
        self.runtime.deinit();
        self.tree.destroy();
        self.parser.destroy();
        self.language.destroy();
    }

    pub fn collectMatches(self: *TestContext) !std.ArrayList(Match) {
        try self.runtime.exec();

        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(self.allocator);

        // FIXME: If we need to access the environment, we need to take a snapshot
        while (try self.runtime.nextMatch()) |match| {
            try matches.append(self.allocator, match);
        }

        return matches;
    }

    pub fn expectMatchKinds(self: *TestContext, expected_kinds: []const []const u8) !void {
        var matches = try self.collectMatches();
        defer matches.deinit(self.allocator);

        if (matches.items.len != expected_kinds.len) {
            std.debug.print("Expected {d} matches, got {d}\n", .{ expected_kinds.len, matches.items.len });
            std.debug.print("Actual matches:\n", .{});
            for (matches.items, 0..) |match, i| {
                std.debug.print("  [{d}] {s}\n", .{ i, match.node.grammarKind() });
            }
            return error.TestUnexpectedResult;
        }

        for (matches.items, expected_kinds) |match, expected_kind| {
            const actual_kind = match.node.grammarKind();
            try std.testing.expectEqualStrings(actual_kind, expected_kind);
        }
    }
};
