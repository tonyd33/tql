//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const VERSION = build_options.version;
// IMPROVE: don't export this
pub const ts = @import("tree-sitter");
// Shared vocabulary: the IRs and types every stage speaks.
pub const cst = @import("lang/cst.zig");
pub const core = @import("lang/core.zig");
pub const diagnostic = @import("lang/diagnostic.zig");
pub const ir = @import("lang/ir.zig");
pub const primitives = @import("lang/primitives.zig");
pub const symbols = @import("lang/symbols.zig");
pub const types = @import("lang/types.zig");

// The stages, in pipeline order. Each is a facade over a private subdirectory.
pub const parse = @import("parse.zig");
pub const desugar = @import("desugar.zig");
pub const type_check = @import("type_check.zig");

const grammar = @import("lang/grammar.zig");
const runtime = @import("runtime.zig");
const pcre2 = @import("regex.zig");
const value = @import("value.zig");

/// The prelude, linked beneath every query.
pub const prelude_source = desugar.prelude_source;

// IMPROVE: don't export this
pub const ds = @import("ds.zig");
pub const Parser = parse.Parser;
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

pub const Profile = runtime.Profile;
pub const profiling_enabled = runtime.profiling_enabled;

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
    tql_parser: parse.Parser,

    pub fn init(config: Config) !Engine {
        return Engine{
            .config = config,
            .tql_parser = try parse.Parser.init(config.allocator),
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
    ) !parse.ParseResult {
        return try self.tql_parser.parseCollecting(query_source);
    }

    /// Parse and desugar a query, then link it against the prelude into a
    /// resolved program. Diagnostics are collected; the caller owns the result.
    pub fn desugarQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !desugar.Program {
        var parsed = try self.tql_parser.parseCollecting(query_source);
        defer parsed.deinit();
        if (parsed.hasErrors()) {
            for (parsed.diagnostics) |d| {
                try sink.report(d.category, d.span, "{s}", .{d.message});
            }
            return error.DesugarFailed;
        }

        var desugarer = try desugar.Desugarer.init(self.config.allocator);
        defer desugarer.deinit();

        // Added first, so prelude names are registered before user declarations
        // and a user definition colliding with one is rejected on insert.
        try self.addPrelude(&desugarer, g, sink);
        try desugarer.add(parsed.source_file, g, sink);

        return try desugarer.finish(parsed.source_file.span, sink);
    }

    /// Parse, desugar, link and type-check a query. Diagnostics are collected;
    /// the caller owns both results.
    ///
    /// The `Checked` borrows nothing from the `Program`, but a `Scheme` in it
    /// may name symbols only the program's interner can spell, so they are
    /// returned together and are meant to be deinitialized together.
    pub fn checkQuery(
        self: *Engine,
        query_source: []const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !CheckedQuery {
        var program = try self.desugarQuery(query_source, g, sink);
        errdefer program.deinit();

        const checked = try type_check.check(self.config.allocator, &program, sink);
        return .{ .program = program, .checked = checked };
    }

    /// Parses and desugars `prelude.tql` into the link.
    ///
    /// Recompiled per link: a module's `SymbolId`s index the registry it was
    /// desugared against, and `is_kind` resolves kind IDs from the grammar, so
    /// a cached one would be valid only per grammar and per registry prefix.
    fn addPrelude(
        self: *Engine,
        desugarer: *desugar.Desugarer,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        var parsed = try self.tql_parser.parseCollecting(prelude_source);
        defer parsed.deinit();
        // Compiled in, so a parse error here is a bug in this repository.
        std.debug.assert(!parsed.hasErrors());

        try desugarer.add(parsed.source_file, g, sink);
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

/// A linked program and its inferred schemes. The two are created together and
/// destroyed together.
pub const CheckedQuery = struct {
    program: desugar.Program,
    checked: type_check.Checked,

    pub fn deinit(self: *CheckedQuery) void {
        self.checked.deinit();
        self.program.deinit();
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
    refAllDecls(parse);
    refAllDecls(grammar);
    refAllDecls(core);
    refAllDecls(desugar);
    refAllDecls(symbols);
    refAllDecls(primitives);
    refAllDecls(types);
    refAllDecls(type_check);
}

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
    try std.testing.expectEqual(null, program.synthesis.get(compose));
    try std.testing.expect(!program.primitives.contains(kind));
}

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
        \\append = \xs -> \ys -> case xs of { Nil -> ys; Cons h t -> Cons h (append t ys) }
        \\flat_map = \xs -> \f -> case xs of { Nil -> Nil; Cons h t -> append (f h) (flat_map t f) }
        \\union = \p -> \q -> \x -> append (p x) (q x)
        \\collect = \p -> \x -> Cons (p x) Nil
        \\not = \b -> case b of { False -> True; True -> False }
        \\and = \a -> \b -> case a of { False -> False; True -> b }
        \\or = \a -> \b -> case a of { False -> b; True -> True }
        \\branch = \condition -> \consequence -> \alternative -> \x -> flat_map (condition x) (\c -> case c of { False -> alternative x; True -> consequence x })
        \\lift = \f -> \x -> pure (f x) x
        \\select = \p -> branch p identity empty
        \\exists = \p -> probe p
        \\any = \source -> \predicate -> probe (compose source (select predicate))
        \\all = \source -> \predicate -> branch (probe (compose source (branch predicate empty identity))) (pure False) (pure True)
        \\contains = \predicate -> exists (compose descendants (select predicate))
        \\within = \predicate -> exists (compose ancestors (select predicate))
        \\or_else = \primary -> \fallback -> branch (probe primary) primary fallback
    , w.written());
}

test "the prelude's schemes are inferred" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var result = try engine.checkQuery("main = children;", g, &sink);
    defer result.deinit();

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    for (result.program.definitions[0..result.program.entry_offset], 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} : ", .{result.program.interner.spelling(definition.symbol)});
        try result.checked.schemeOf(definition.symbol).?.format(&w.writer);
    }

    try std.testing.expectEqualStrings(
        \\append : [a] -> [a] -> [a]
        \\flat_map : [a] -> (a -> [b]) -> [b]
        \\union : (a -> [b]) -> (a -> [b]) -> a -> [b]
        \\collect : (a -> b) -> a -> [b]
        \\not : Bool -> Bool
        \\and : Bool -> Bool -> Bool
        \\or : Bool -> Bool -> Bool
        \\branch : (a -> [Bool]) -> (a -> [b]) -> (a -> [b]) -> a -> [b]
        \\lift : (a -> b) -> a -> [b]
        \\select : (a -> [Bool]) -> a -> [a]
        \\exists : (a -> [b]) -> a -> [Bool]
        \\any : (a -> [b]) -> (b -> [Bool]) -> a -> [Bool]
        \\all : (a -> [b]) -> (b -> [Bool]) -> a -> [Bool]
        \\contains : (Node -> [Bool]) -> Node -> [Bool]
        \\within : (Node -> [Bool]) -> Node -> [Bool]
        \\or_else : (a -> [b]) -> (a -> [b]) -> a -> [b]
    , w.written());
}

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

test "a case binds a constructor's field at its instantiated type" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var result = try engine.checkQuery(
        \\type Maybe a = Just a | Nothing;
        \\or_default m d = case m of { Just x -> x; Nothing -> d };
        \\main = pure (or_default (Just 42) 0);
    , g, &sink);
    defer result.deinit();

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    for (result.program.entryDefinitions(), 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} : ", .{result.program.interner.spelling(definition.symbol)});
        try result.checked.schemeOf(definition.symbol).?.format(&w.writer);
    }

    try std.testing.expectEqualStrings(
        \\or_default : Maybe a -> a -> a
        \\main : Node -> [Int]
    , w.written());
}
