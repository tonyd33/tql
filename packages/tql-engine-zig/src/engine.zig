const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const runtime = @import("runtime.zig");
const ast = @import("ast.zig");
const query = @import("query.zig");
const Match = query.Match;
const Query = query.Query;
const QueryResult = query.QueryResult;
const Language = @import("language.zig").Language;

pub const Config = struct {
    allocator: Allocator,
    max_threads: ?usize = null,
};

pub const CompileStats = struct {
    parse_time_us: u64 = 0,
    compile_time_us: u64 = 0,
    instruction_count: usize = 0,
};

/// A "batteries-included" interface to interface with the TQL primitives.
pub const Engine = struct {
    // TODO: complete this. unsure of interface
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
};
