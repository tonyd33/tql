//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const VERSION = build_options.version;
// IMPROVE: don't export this
pub const ts = @import("tree-sitter");
pub const cst = @import("cst.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const ir = @import("ir.zig");

const runtime = @import("runtime.zig");
const runtime_types = @import("runtime/types.zig");
const pcre2 = @import("regex.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const grammar = @import("grammar.zig");
const value = @import("value.zig");

pub const core = @import("core.zig");
pub const desugar = @import("desugar.zig");
pub const link = @import("link.zig");

/// The prelude, linked beneath every query. Compiling it needs a parser, which
/// `desugar.zig` does not import.
pub const prelude_source = @embedFile("prelude.tql");
pub const resolve = @import("resolve.zig");
pub const primitives = @import("primitives.zig");
pub const symbols = @import("symbols.zig");
pub const types = @import("types.zig");

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
    pub fn parseQuery(self: *Engine, query_source: []const u8) !cst.SourceFile {
        return try self.tql_parser.parse(query_source);
    }

    /// Parse a query, keeping the diagnostics rather than collapsing them into
    /// a bare error. Caller owns the result.
    pub fn parseQueryCollecting(
        self: *Engine,
        query_source: []const u8,
    ) !parser.ParseResult {
        return try self.tql_parser.parseCollecting(query_source);
    }

    /// Parse and desugar a query, then link it against the prelude into a
    /// resolved program. Diagnostics are collected; the caller owns the result.
    pub fn desugarQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !link.Program {
        var parsed = try self.tql_parser.parseCollecting(query_source);
        defer parsed.deinit();
        if (parsed.hasErrors()) {
            for (parsed.diagnostics) |d| {
                try sink.report(d.category, d.span, "{s}", .{d.message});
            }
            return error.DesugarFailed;
        }

        const allocator = self.config.allocator;

        var linker = try link.Linker.init(allocator);
        defer linker.deinit();

        // Added first, so prelude names are registered before user declarations
        // and a user definition colliding with one is rejected on insert.
        try linker.add(try self.desugarPrelude(&linker, g, sink));

        try linker.add(try desugar.module(
            allocator,
            linker.arena.allocator(),
            linker.interner(),
            &linker.synthesis,
            parsed.source_file,
            g,
            sink,
        ));

        return try linker.finish(parsed.source_file.span, sink);
    }

    /// Parses and desugars `prelude.tql` into a module.
    ///
    /// Recompiled per link: a module's `SymbolId`s index the registry it was
    /// desugared against, and `is_kind` resolves kind IDs from the grammar, so
    /// a cached one would be valid only per grammar and per registry prefix.
    fn desugarPrelude(
        self: *Engine,
        linker: *link.Linker,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !desugar.Module {
        var parsed = try self.tql_parser.parseCollecting(prelude_source);
        defer parsed.deinit();
        // Compiled in, so a parse error here is a bug in this repository.
        std.debug.assert(!parsed.hasErrors());

        return try desugar.module(
            self.config.allocator,
            linker.arena.allocator(),
            linker.interner(),
            &linker.synthesis,
            parsed.source_file,
            g,
            sink,
        );
    }

    /// Parse + compile a TQL query for a given target language.
    /// Returned Query owns its ProgramImage.
    pub fn compile(self: *Engine, query_source: []const u8, g: *const Grammar) !Query {
        _ = self;
        _ = query_source;
        _ = g;
        return error.DesugaringUnimplemented;
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
    refAllDecls(cst);
    refAllDecls(diagnostic);
    refAllDecls(parser);
    refAllDecls(compiler);
    refAllDecls(grammar);
    refAllDecls(core);
    refAllDecls(desugar);
    refAllDecls(resolve);
    refAllDecls(symbols);
    refAllDecls(primitives);
    refAllDecls(types);
    refAllDecls(link);
}

// The kind and field ids are resolved once, at desugaring, and nothing
// downstream can recover them — so a wrong id would otherwise surface only in
// Stage 5.
test "synthesized symbols carry the grammar ids they resolved" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery(
        "main = children | is_kind :class_declaration | .name;",
        g,
        &sink,
    );
    defer program.deinit();

    const kind = program.interner.lookup("is_kind[class_declaration]").?;
    const kind_what = program.synthesis.get(kind).?;
    try std.testing.expectEqualStrings("class_declaration", kind_what.kind_test.name);
    try std.testing.expectEqual(
        g.language.idForNodeKind("class_declaration", true),
        kind_what.kind_test.id,
    );

    const field = program.interner.lookup("field[name]").?;
    const field_what = program.synthesis.get(field).?;
    try std.testing.expectEqualStrings("name", field_what.field.name);
    try std.testing.expectEqual(g.language.fieldIdForName("name"), field_what.field.id);

    // A primitive is not synthesized, and a synthesized symbol is not a primitive.
    const compose = program.interner.lookup("compose").?;
    try std.testing.expect(program.primitives.contains(compose));
    try std.testing.expectEqual(@as(?desugar.Synthesis, null), program.synthesis.get(compose));
    try std.testing.expect(!program.primitives.contains(kind));
}

// A corpus fixture cannot assert these: the printer shows entry definitions
// only.
test "the prelude's bodies compile to Core" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery("main = children;", g, &sink);
    defer program.deinit();

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    const printer: core.Printer = .{ .interner = &program.interner };
    for (program.definitions[0..program.entry_offset], 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} = ", .{program.interner.spelling(definition.symbol)});
        try printer.term(definition.body, &w.writer);
    }

    try std.testing.expectEqualStrings(
        \\select = \p -> branch p identity empty
        \\exists = \p -> probe p
        \\any = \source -> \predicate -> probe (compose source (select predicate))
        \\all = \source -> \predicate -> branch (probe (compose source (branch predicate empty identity))) (pure false) (pure true)
        \\contains = \predicate -> exists (compose descendants (select predicate))
        \\within = \predicate -> exists (compose ancestors (select predicate))
        \\or_else = \primary -> \fallback -> branch (probe primary) primary fallback
    , w.written());
}

// Callees precede callers across the module boundary.
test "linked components order prelude callees before user callers" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery("main = contains (\\n -> [true]);", g, &sink);
    defer program.deinit();

    try std.testing.expectEqualStrings("main", program.interner.spelling(program.entry));

    var seen_select = false;
    var seen_contains = false;
    for (program.components) |component| {
        for (component) |index| {
            const spelling = program.interner.spelling(program.definitions[index].symbol);
            if (std.mem.eql(u8, spelling, "select")) seen_select = true;
            if (std.mem.eql(u8, spelling, "contains")) {
                try std.testing.expect(seen_select);
                seen_contains = true;
            }
            if (std.mem.eql(u8, spelling, "main")) try std.testing.expect(seen_contains);
        }
    }
    try std.testing.expect(seen_contains);
}
