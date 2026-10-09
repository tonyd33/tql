//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const VERSION = build_options.version;
// IMPROVE: don't export this
pub const ts = @import("tree-sitter");
// Shared vocabulary: the IRs and types every stage speaks.
pub const cst = @import("lang/cst.zig");
pub const core = @import("core.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const primitives = @import("primitives.zig");
pub const types = core.types;

// The stages, in pipeline order. Each is a facade over a private subdirectory.
pub const parse = @import("parse.zig");
pub const tql_to_core = @import("tql_to_core.zig");
pub const type_check = @import("type_check.zig");
pub const core_to_core = @import("core_to_core.zig");
pub const core_to_stg = @import("core_to_stg.zig");
pub const stg = @import("stg.zig");

pub const inspect = @import("inspect.zig");

const grammar = @import("lang/grammar.zig");
const string_literal = @import("lang/string_literal.zig");
const pcre2 = @import("regex.zig");

/// The prelude, linked beneath every query.
pub const prelude_source = @embedFile("prelude.tql");

pub const load = @import("load.zig");
pub const Loader = load.Loader;

/// The libraries every host can import.
pub const bundled_modules: []const load.Bundled = &.{};

// IMPROVE: don't export this
pub const ds = @import("ds.zig");
pub const Parser = parse.Parser;
pub const Grammar = grammar.Grammar;
pub const GrammarRegistry = grammar.Registry;

/// How long each stage of compiling a query took.
pub const CompileTimes = struct {
    parse: std.Io.Duration = .zero,
    /// Reading and parsing every module the query imports.
    load: std.Io.Duration = .zero,
    /// Parsing and desugaring `prelude.tql`.
    prelude: std.Io.Duration = .zero,
    /// Desugaring and linking the query and its imports.
    desugar: std.Io.Duration = .zero,
    type_check: std.Io.Duration = .zero,
    /// `core_to_core`.
    simplify: std.Io.Duration = .zero,
    translate: std.Io.Duration = .zero,

    /// Write each stage as `<stage>_ns`.
    pub fn jsonStringify(self: CompileTimes, jws: anytype) !void {
        try jws.beginObject();
        inline for (std.meta.fields(CompileTimes)) |f| {
            try jws.objectField(f.name ++ "_ns");
            try jws.write(@field(self, f.name).nanoseconds);
        }
        try jws.endObject();
    }
};

pub const Config = struct {
    allocator: Allocator,
    // Do I really need this?
    io: std.Io,
};

/// A "batteries-included" interface to the TQL primitives.
pub const Engine = struct {
    config: Config,
    tql_parser: parse.Parser,
    /// Where an imported module's source comes from, besides `bundled`.
    loader: ?Loader = null,
    bundled: []const load.Bundled = bundled_modules,
    /// What the latest compilation read besides its query.
    sources: diagnostic.Sources,
    /// How long the latest compilation's stages took, up to type checking.
    times: CompileTimes = .{},

    pub fn init(config: Config) !Engine {
        return Engine{
            .config = config,
            .tql_parser = try parse.Parser.init(config.allocator),
            .sources = .init(config.allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.sources.deinit();
        self.tql_parser.deinit();
    }

    /// The source a span of the latest compilation points into, where
    /// `entry` is its query.
    pub fn sourceOf(self: *const Engine, id: diagnostic.SourceId, entry: diagnostic.Source) diagnostic.Source {
        return self.sources.get(id, entry);
    }

    /// Parse a query, keeping the diagnostics rather than collapsing them into
    /// a bare error. Caller owns the result.
    pub fn parseQueryCollecting(
        self: *Engine,
        query_source: []const u8,
    ) !parse.ParseResult {
        return try self.tql_parser.parseCollecting(query_source, .entry);
    }

    /// Parse and desugar a query, then link it against the prelude and every
    /// module it imports into a resolved program. Diagnostics are collected;
    /// the caller owns the result.
    pub fn desugarQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !core.Program {
        self.times = .{};
        const start = std.Io.Timestamp.now(self.config.io, .real);
        var parsed = try self.tql_parser.parseCollecting(query_source, .entry);
        defer parsed.deinit();
        self.times.parse = start.untilNow(self.config.io, .real);
        if (parsed.hasErrors()) {
            try sink.extend(parsed.diagnostics);
            return error.DesugarFailed;
        }
        return try self.desugarParsed(parsed.source_file, g, sink);
    }

    /// `desugarQuery` for a query already parsed, without syntax errors.
    pub fn desugarParsed(
        self: *Engine,
        query: cst.SourceFile,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !core.Program {
        const io = self.config.io;
        self.sources.clear();
        var desugarer = try tql_to_core.Desugarer.init(self.config.allocator);
        defer desugarer.deinit();

        const prelude_start = std.Io.Timestamp.now(io, .real);
        try self.addPrelude(&desugarer, sink);
        self.times.prelude = prelude_start.untilNow(io, .real);

        var shipped: load.BundledLoader = .{ .modules = self.bundled };
        var loaders: std.ArrayList(Loader) = .empty;
        defer loaders.deinit(self.config.allocator);
        if (self.loader) |l| try loaders.append(self.config.allocator, l);
        try loaders.append(self.config.allocator, shipped.loader());

        var graph: load.Graph = .{
            .gpa = self.config.allocator,
            .parser = &self.tql_parser,
            .loaders = loaders.items,
            .sources = &self.sources,
        };
        defer graph.deinit();
        const load_start = std.Io.Timestamp.now(io, .real);
        try graph.visitEntry(query, sink);
        if (sink.hasErrors()) return error.DesugarFailed;
        try graph.checkGrammars(g, sink);
        if (sink.hasErrors()) return error.DesugarFailed;
        self.times.load = load_start.untilNow(io, .real);

        const desugar_start = std.Io.Timestamp.now(io, .real);
        try graph.link(&desugarer, g, sink);
        const program = try desugarer.finish(query.span, sink);
        self.times.desugar = desugar_start.untilNow(io, .real);
        return program;
    }

    /// Parse, desugar, link and type-check a query. Diagnostics are collected;
    /// the caller owns the result and its environment holds every scheme
    /// inference found.
    pub fn checkQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !core.Program {
        var program = try self.desugarQuery(query_source, g, sink);
        errdefer program.deinit();

        const start = std.Io.Timestamp.now(self.config.io, .real);
        try type_check.check(self.config.allocator, &program, sink);
        self.times.type_check = start.untilNow(self.config.io, .real);
        return program;
    }

    /// Parses and desugars `prelude.tql` into the link.
    ///
    /// Recompiled per link: a module's `SymbolId`s index the registry it was
    /// desugared against, so a cached one would be valid only per registry
    /// prefix. The prelude is grammar-generic.
    fn addPrelude(
        self: *Engine,
        desugarer: *tql_to_core.Desugarer,
        sink: *diagnostic.Sink,
    ) !void {
        const id = try self.sources.add(.{ .name = "prelude.tql", .text = prelude_source });
        var parsed = try self.tql_parser.parseCollecting(prelude_source, id);
        defer parsed.deinit();
        // Compiled in, so a parse error here is a bug in this repository.
        if (parsed.hasErrors()) return error.PreludeInvalid;

        try desugarer.add(.prelude, &.{}, parsed.source_file, null, sink);
    }

    /// Check and translate a query once, for running against many targets.
    ///
    /// The result is immutable and safe to share across threads: every
    /// per-run mutable structure lives in the `Machine` that `run` builds.
    pub fn compileQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !CompiledQuery {
        const checked = try self.checkQuery(query_source, g, sink);
        var compiled = try CompiledQuery.init(self.config.allocator, self.config.io, checked, g, .{});
        var times = self.times;
        times.simplify = compiled.times.simplify;
        times.translate = compiled.times.translate;
        compiled.times = times;
        return compiled;
    }
};

/// A query checked and translated once, run against many targets.
pub const CompiledQuery = struct {
    checked: core.Program,
    translated: stg.Program,
    grammar: *const Grammar,
    allocator: Allocator,
    io: std.Io,
    /// How long compiling took. `init` measures only `simplify` and
    /// `translate`; `Engine.compileQuery` fills in the rest.
    times: CompileTimes = .{},

    pub const Options = struct {
        /// The rewrites `core_to_core` runs before translating. Null skips it.
        simplify: ?core_to_core.Options = .{},
    };

    /// Simplify and translate `checked`, taking ownership of it even on
    /// failure.
    pub fn init(
        allocator: Allocator,
        io: std.Io,
        checked: core.Program,
        g: *const Grammar,
        options: Options,
    ) !CompiledQuery {
        var program = checked;
        errdefer program.deinit();

        var times: CompileTimes = .{};
        const simplify_start = std.Io.Timestamp.now(io, .real);
        if (options.simplify) |rewrites| try core_to_core.run(&program, rewrites);
        times.simplify = simplify_start.untilNow(io, .real);

        const translate_start = std.Io.Timestamp.now(io, .real);
        const translated = try core_to_stg.translate(allocator, &program);
        times.translate = translate_start.untilNow(io, .real);
        return .{
            .checked = program,
            .translated = translated,
            .grammar = g,
            .allocator = allocator,
            .io = io,
            .times = times,
        };
    }

    pub fn deinit(self: *CompiledQuery) void {
        self.translated.deinit();
        self.checked.deinit();
    }

    /// Run against one in-memory target buffer.
    ///
    /// `target` must outlive the returned values: a node points into the tree
    /// parsed from it, and serializing one slices it for `text`.
    ///
    /// `scratch` is the machine's arena. The caller resets it between files.
    pub fn run(
        self: *const CompiledQuery,
        target: []const u8,
        target_path: ?[]const u8,
        result_allocator: Allocator,
        scratch: Allocator,
    ) !RunOutcome {
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();
        try source_parser.setLanguage(self.grammar.language);

        const parse_start = std.Io.Timestamp.now(self.io, .real);
        const tree = source_parser.parseString(target, null) orelse
            return error.TargetParseFailed;
        defer tree.destroy();
        const parse_time = parse_start.untilNow(self.io, .real);

        var outcome = try self.runTree(tree, target, target_path, result_allocator, scratch);
        outcome.parse_time = parse_time;
        return outcome;
    }

    /// `run` against `target` already parsed into `tree`. The outcome's
    /// `parse_time` is zero.
    pub fn runTree(
        self: *const CompiledQuery,
        tree: *const ts.Tree,
        target: []const u8,
        target_path: ?[]const u8,
        result_allocator: Allocator,
        scratch: Allocator,
    ) !RunOutcome {
        const query_start = std.Io.Timestamp.now(self.io, .real);

        var machine = try stg.Machine.init(scratch, self.allocator, &self.translated);
        defer machine.deinit();
        machine.target = .{ .source = target, .path = target_path };

        const entry = machine.global(self.checked.entry) orelse
            return error.MissingEntry;

        const root = try scratch.create(stg.Thunk);
        root.* = stg.Thunk.value(.{ .node = .{ .inner = tree.rootNode() } });
        const outputs = try machine.apply(try machine.force(entry), &.{root});

        // Serialized here, while the tree is alive. A node value borrows it,
        // so it cannot outlive this call.
        var w: std.Io.Writer.Allocating = .init(result_allocator);
        errdefer w.deinit();
        var jws = std.json.Stringify{ .writer = &w.writer };
        const count = try machine.serializeList(outputs, &jws);

        const query_time = query_start.untilNow(self.io, .real);

        return .{
            .json = try w.toOwnedSlice(),
            .count = count,
            .parse_time = .zero,
            .query_time = query_time,
        };
    }
};

/// One target's results: the outputs as a JSON array, and what it cost.
pub const RunOutcome = struct {
    json: []const u8,
    count: usize,
    parse_time: std.Io.Duration,
    query_time: std.Io.Duration,
};

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@This());
    refAllDecls(pcre2);
    refAllDecls(cst);
    refAllDecls(diagnostic);
    refAllDecls(parse);
    refAllDecls(grammar);
    refAllDecls(string_literal);
    refAllDecls(core);
    refAllDecls(core.symbols);
    refAllDecls(core.datatypes);
    refAllDecls(tql_to_core);
    refAllDecls(primitives);
    refAllDecls(types);
    refAllDecls(type_check);
    refAllDecls(core_to_core);
    refAllDecls(core_to_stg);
    refAllDecls(stg);
    refAllDecls(inspect);
}

test "a module both bundled and loaded is ambiguous" {
    const allocator = std.testing.allocator;
    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    var engine = try Engine.init(.{ .allocator = allocator, .io = std.testing.io });
    defer engine.deinit();
    engine.bundled = &.{.{ .name = "Lib", .path = "bundled/Lib.tql", .text = "module Lib; answer = 42;" }};
    var modules: load.BundledLoader = .{ .modules = &.{.{ .name = "Lib", .path = "lib/Lib.tql", .text = "module Lib; answer = 1;" }} };
    engine.loader = modules.loader();
    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    try std.testing.expectError(error.DesugarFailed, engine.desugarQuery(
        "import Lib; main root = [answer];",
        try grammars.get("typescript"),
        &sink,
    ));
    try std.testing.expectEqual(1, sink.items().len);
    try std.testing.expectEqual(.ambiguous_module, sink.items()[0].category);
    try std.testing.expectEqualStrings("`Lib` is found as both `lib/Lib.tql` and `bundled/Lib.tql`", sink.items()[0].message);
}

test "compileQuery times every stage" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = std.testing.io });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var compiled = try engine.compileQuery("main = children;", g, &sink);
    defer compiled.deinit();

    inline for (std.meta.fields(CompileTimes)) |f| {
        try std.testing.expect(@field(compiled.times, f.name).nanoseconds > 0);
    }
}

test "compile times serialize as <stage>_ns" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    var jws: std.json.Stringify = .{ .writer = &w.writer };
    try jws.write(CompileTimes{ .parse = .fromNanoseconds(1), .translate = .fromNanoseconds(7) });
    try std.testing.expectEqualStrings(
        \\{"parse_ns":1,"load_ns":0,"prelude_ns":0,"desugar_ns":0,"type_check_ns":0,"simplify_ns":0,"translate_ns":7}
    , w.written());
}
