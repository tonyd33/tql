//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const VERSION = build_options.version;
// IMPROVE: don't export this
pub const ts = @import("tree-sitter");
pub const ast = @import("ast.zig");
pub const ir = @import("ir.zig");

const runtime = @import("runtime.zig");
const runtime_types = @import("runtime/types.zig");
const pcre2 = @import("regex.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const grammar = @import("grammar.zig");
const value = @import("value.zig");

// IMPROVE: don't export this
pub const ds = @import("ds.zig");
pub const Parser = parser.Parser;
pub const Compiler = compiler.Compiler;
pub const Grammar = grammar.Grammar;
pub const GrammarRegistry = grammar.Registry;

pub const Value = value.Value;
pub const NodeSnapshot = value.NodeSnapshot;
pub const RecordEntry = value.RecordEntry;
pub const RecordView = value.RecordView;
pub const RecordIterator = value.RecordIterator;
pub const ListView = value.ListView;

pub const Config = struct {
    allocator: Allocator,
    // Do I really need this?
    io: std.Io,
};

pub const Profile = runtime_types.Profile;
pub const profiling_enabled = runtime_types.profiling_enabled;

pub const RunStats = struct {
    parse_time: std.Io.Duration,
    query_time: std.Io.Duration,
    profile: Profile = .{},
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
    /// Returned Query owns its ProgramImage.
    pub fn compile(self: *Engine, query_source: []const u8, g: *const Grammar) !Query {
        const source_file = try self.tql_parser.parse(query_source);
        defer source_file.deinit(self.config.allocator);

        var c = compiler.Compiler.init(self.config.allocator, g.language);
        defer c.deinit();

        const program_image = try c.compile(self.config.allocator, source_file);
        return .{
            .program_image = program_image,
            .grammar = g,
            .allocator = self.config.allocator,
            .io = self.config.io,
        };
    }
};

pub const Query = struct {
    program_image: ir.ProgramImage,
    grammar: *const Grammar,
    allocator: Allocator,
    // Do I really want this...?
    io: std.Io,

    pub fn deinit(self: *Query) void {
        self.program_image.deinit();
    }

    pub fn instructions(self: *const Query) []const ir.Instruction {
        return self.program_image.instructions;
    }

    /// Run against one in-memory query target buffer. Caller owns returned RunResult
    /// and must call deinit(). `query_target` must outlive the call but not the result.
    pub fn run(
        self: *Query,
        query_target: []const u8,
        result_allocator: Allocator,
        scratch_allocator: Allocator,
    ) !RunResult {
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();
        try source_parser.setLanguage(self.grammar.language);

        const parse_start = std.Io.Timestamp.now(self.io, .real);
        const tree = source_parser.parseString(query_target, null) orelse return error.SourceParseFailed;
        defer tree.destroy();
        const parse_time = parse_start.untilNow(self.io, .real);

        var rt = runtime.Runtime.init(.{
            .tree = tree,
            .source = query_target,
            .instructions = self.program_image.instructions,
            .regexes = self.program_image.regexes,
            .param_var_arena = self.program_image.param_var_arena,
            .allocator = scratch_allocator,
        });
        try rt.exec();
        defer rt.deinit();

        var values: std.ArrayList(Value) = .empty;
        errdefer {
            for (values.items) |*v| v.deinit(result_allocator);
            values.deinit(result_allocator);
        }

        const query_start = std.Io.Timestamp.now(self.io, .real);
        while (try rt.next()) |runtime_value| {
            const v = try runtime_value.toPublic(result_allocator, query_target);
            try values.append(result_allocator, v);
        }
        const query_time = query_start.untilNow(self.io, .real);

        return .{
            .values = values,
            .stats = .{
                .parse_time = parse_time,
                .query_time = query_time,
                .profile = rt.profile,
            },
            .allocator = result_allocator,
        };
    }
};

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@This());
    refAllDecls(runtime);
    refAllDecls(pcre2);
    refAllDecls(ast);
    refAllDecls(parser);
    refAllDecls(compiler);
    refAllDecls(grammar);
}
