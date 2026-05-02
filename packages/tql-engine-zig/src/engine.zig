const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const parser = @import("./parser.zig");
const compiler = @import("./compiler/core.zig");
const runtime = @import("./runtime.zig");
const ast = @import("./ast.zig");

// Mirror a ts.Node. We want this to have its own lifetime independent of the tree sitter AST
// that backs a ts.Node.
pub const Node = struct {
    kind: []const u8,
    text: []const u8,
    start_byte: u32,
    end_byte: u32,
    start_point: runtime.Point,
    end_point: runtime.Point,
    child_count: u32,
    named_child_count: u32,
    is_named: bool,
    is_missing: bool,
    is_extra: bool,

    pub fn fromTsNode(ts_node: ts.Node, source: []const u8) Node {
        const start_point = ts_node.startPoint();
        const end_point = ts_node.endPoint();
        return Node{
            .kind = ts_node.kind(),
            .text = source[ts_node.startByte()..ts_node.endByte()],
            .start_byte = ts_node.startByte(),
            .end_byte = ts_node.endByte(),
            .start_point = .{ .row = start_point.row, .column = start_point.column },
            .end_point = .{ .row = end_point.row, .column = end_point.column },
            .child_count = ts_node.childCount(),
            .named_child_count = ts_node.namedChildCount(),
            .is_named = ts_node.isNamed(),
            .is_missing = ts_node.isMissing(),
            .is_extra = ts_node.isExtra(),
        };
    }
};

pub const Value = union(enum) {
    nothing: void,
    string: []const u8,
    node: Node,
    range: runtime.Range,

    pub fn fromRuntimeValue(val: runtime.Value, source: []const u8) Value {
        return switch (val) {
            .nothing => .{ .nothing = {} },
            .string => |s| .{ .string = s },
            .node => |n| .{ .node = Node.fromTsNode(n, source) },
            .range => |r| .{ .range = r },
            else => .{ .nothing = {} },
        };
    }
};

pub const Match = struct {
    node: Node,
    captures: std.StringHashMap(Value),

    pub fn deinit(self: *Match) void {
        self.captures.deinit();
    }

    pub fn getCapture(self: *const Match, name: []const u8) ?Value {
        return self.captures.get(name);
    }
};

pub const Config = struct {
    allocator: Allocator,
    max_threads: ?usize = null,
};

// IMPROVE: There's gotat be some comptime stuff we can do to toggle on different builds
pub const Language = enum {
    c,
    typescript,
    tsx,

    pub fn getTreeSitterLanguage(self: Language) *ts.Language {
        return switch (self) {
            .c => tree_sitter_c(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
        };
    }

    pub fn fromPath(path: []const u8) ?Language {
        if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
        if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
        if (std.mem.endsWith(u8, path, ".c")) return .c;
        if (std.mem.endsWith(u8, path, ".h")) return .c;
        return null;
    }

    pub fn name(self: Language) []const u8 {
        return switch (self) {
            .c => "c",
            .typescript => "typescript",
            .tsx => "tsx",
        };
    }
};

pub const QueryStats = struct {
    parse_time_us: u64 = 0,
    execute_time_us: u64 = 0,
};

pub const QueryResult = struct {
    matches: []Match,
    stats: QueryStats,
    allocator: Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.matches) |*match| {
            match.deinit();
        }
        self.allocator.free(self.matches);
    }
};

pub const CompiledQuery = struct {
    program: compiler.Program,
    language: Language,
    variable_names: std.AutoHashMap(runtime.VariableId, []const u8),
    allocator: Allocator,

    pub fn run(self: *CompiledQuery, source_code: []const u8) !QueryResult {
        var stats = QueryStats{};

        var parse_timer = try std.time.Timer.start();
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();

        try source_parser.setLanguage(self.language.getTreeSitterLanguage());
        const source_tree = source_parser.parseString(source_code, null) orelse return error.SourceParseFailed;
        defer source_tree.destroy();
        stats.parse_time_us = parse_timer.read() / 1000;

        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var execute_timer = try std.time.Timer.start();
        var rt = runtime.Runtime.init(.{
            .tree = source_tree,
            .source = source_code,
            .instructions = self.program.instructions,
            .regexes = self.program.regexes,
            .data = &[_]u8{},
            .allocator = allocator,
        });
        // FIXME: Regex assignments will fail. The regexes need to be owned by QueryResult
        defer rt.deinit();

        try rt.exec();

        var matches_list = std.ArrayList(Match){};
        defer matches_list.deinit(allocator);
        errdefer {
            for (matches_list.items) |*m| m.deinit();
        }

        while (try rt.nextMatch()) |runtime_match| {
            // Create enriched match with string-based captures
            // NOTE: If we're able to defer this to the consumer, we can save
            // a ton of heap allocations
            const enriched_match = try self.enrichMatch(
                runtime_match,
                source_code,
                &self.variable_names,
            );
            try matches_list.append(self.allocator, enriched_match);
        }

        const matches = try matches_list.toOwnedSlice(self.allocator);
        stats.execute_time_us = execute_timer.read() / 1000;

        return QueryResult{
            .matches = matches,
            .stats = stats,
            .allocator = self.allocator,
        };
    }

    fn enrichMatch(
        self: *CompiledQuery,
        runtime_match: runtime.Match,
        source_code: []const u8,
        variable_names: *const std.AutoHashMap(runtime.VariableId, []const u8),
    ) !Match {
        const enriched_node = Node.fromTsNode(runtime_match.node, source_code);

        var captures = std.StringHashMap(Value).init(self.allocator);
        errdefer captures.deinit();

        var env_snapshot = try runtime_match.environment.snapshot(self.allocator);
        defer env_snapshot.deinit();

        var env_iter = env_snapshot.iterator();
        while (env_iter.next()) |entry| {
            const var_id = entry.key_ptr.*;
            const runtime_value = entry.value_ptr.*;

            if (variable_names.get(var_id)) |var_name| {
                const enriched_value = Value.fromRuntimeValue(runtime_value, source_code);
                try captures.put(var_name, enriched_value);
            }
        }

        return Match{
            .node = enriched_node,
            .captures = captures,
        };
    }

    pub fn deinit(self: *CompiledQuery) void {
        self.program.deinit();

        var iter = self.variable_names.valueIterator();
        while (iter.next()) |name| {
            self.allocator.free(name.*);
        }
        self.variable_names.deinit();
    }
};

pub const CompileStats = struct {
    parse_time_us: u64 = 0,
    compile_time_us: u64 = 0,
    instruction_count: usize = 0,
};

pub const Engine = struct {
    config: Config,
    tql_parser: parser.Parser,

    pub fn init(config: Config) !Engine {
        return Engine{
            .config = config,
            .tql_parser = try parser.Parser.init(config.allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.tql_parser.deinit();
    }

    pub fn compileTql(
        self: *Engine,
        query_source: []const u8,
        // FIXME: We're supposed to detect the language.
        language: Language,
    ) !struct { query: CompiledQuery, stats: CompileStats } {
        var stats = CompileStats{};

        var parse_timer = try std.time.Timer.start();
        const source_file = try self.tql_parser.parse(query_source);
        defer source_file.deinit(self.config.allocator);
        stats.parse_time_us = parse_timer.read() / 1000;

        // TODO: Arena allocate. Maybe. not super important.
        var compile_timer = try std.time.Timer.start();
        var query_compiler = compiler.Compiler.init(
            self.config.allocator,
            language.getTreeSitterLanguage(),
        );
        defer query_compiler.deinit();

        const program = try query_compiler.compile(source_file);
        stats.compile_time_us = compile_timer.read() / 1000;
        stats.instruction_count = program.instructions.len;

        var variable_names = std.AutoHashMap(runtime.VariableId, []const u8).init(self.config.allocator);
        errdefer {
            var iter = variable_names.valueIterator();
            while (iter.next()) |name| {
                self.config.allocator.free(name.*);
            }
            variable_names.deinit();
        }

        var var_iter = query_compiler.variables.map.iterator();
        while (var_iter.next()) |entry| {
            const name_copy = try self.config.allocator.dupe(u8, entry.key_ptr.*);
            try variable_names.put(entry.value_ptr.*, name_copy);
        }

        return .{
            .query = CompiledQuery{
                .program = program,
                .language = language,
                .variable_names = variable_names,
                .allocator = self.config.allocator,
            },
            .stats = stats,
        };
    }

    // for debug
    pub fn parseQuery(self: *Engine, query_source: []const u8) !ast.SourceFile {
        return try self.tql_parser.parse(query_source);
    }
};

extern fn tree_sitter_c() *ts.Language;
extern fn tree_sitter_typescript() *ts.Language;
extern fn tree_sitter_tsx() *ts.Language;
