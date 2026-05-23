const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const runtime = @import("runtime.zig");
const ast = @import("ast.zig");
const query = @import("query.zig");
const Value = query.Value;
const Query = query.Query;
const Language = @import("language.zig").Language;

pub const Config = struct {
    allocator: Allocator,
};

pub const RunStats = struct {
    parse_time_ns: u64 = 0,
    query_time_ns: u64 = 0,
};

pub const RunResult = struct {
    values: std.ArrayList(Value),
    stats: RunStats,
    allocator: Allocator,

    pub fn deinit(self: *RunResult) void {
        for (self.values.items) |*v| v.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }
};

/// A "batteries-included" interface to the TQL primitives.
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

    // for debug
    pub fn parseQuery(self: *Engine, query_source: []const u8) !ast.SourceFile {
        return try self.tql_parser.parse(query_source);
    }

    /// Parse + compile a TQL query for a given target language.
    /// Returned CompiledQuery owns its ProgramImage.
    pub fn compile(self: *Engine, query_source: []const u8, language: Language) !CompiledQuery {
        const source_file = try self.tql_parser.parse(query_source);
        defer source_file.deinit(self.config.allocator);

        var c = compiler.Compiler.init(self.config.allocator, language.getTreeSitterLanguage());
        defer c.deinit();

        const program_image = try c.compile(self.config.allocator, source_file);
        return .{
            .program_image = program_image,
            .language = language,
            .allocator = self.config.allocator,
        };
    }
};

pub const CompiledQuery = struct {
    program_image: runtime.ProgramImage,
    language: Language,
    allocator: Allocator,

    pub fn deinit(self: *CompiledQuery) void {
        self.program_image.deinit();
    }

    pub fn instructions(self: *const CompiledQuery) []const runtime.Instruction {
        return self.program_image.instructions;
    }

    /// Run against one in-memory query target buffer. Caller owns returned
    /// values (deep-copied into `result_allocator`). `query_target` must
    /// outlive the call but not the result.
    pub fn run(
        self: *CompiledQuery,
        query_target: []const u8,
        result_allocator: Allocator,
        scratch_allocator: Allocator,
    ) !RunResult {
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();
        try source_parser.setLanguage(self.language.getTreeSitterLanguage());

        var parse_timer = try std.time.Timer.start();
        const tree = source_parser.parseString(query_target, null) orelse return error.SourceParseFailed;
        defer tree.destroy();
        const parse_time_ns = parse_timer.read();

        var q = Query.init(
            &self.program_image,
            self.language,
            query_target,
            tree,
            scratch_allocator,
        );
        try q.exec();
        defer q.deinit();

        var values: std.ArrayList(Value) = .empty;
        errdefer {
            for (values.items) |*v| v.deinit(result_allocator);
            values.deinit(result_allocator);
        }

        var query_timer = try std.time.Timer.start();
        while (try q.next(result_allocator)) |value| {
            try values.append(result_allocator, value);
        }
        const query_time_ns = query_timer.read();

        return .{
            .values = values,
            .stats = .{
                .parse_time_ns = parse_time_ns,
                .query_time_ns = query_time_ns,
            },
            .allocator = result_allocator,
        };
    }
};
