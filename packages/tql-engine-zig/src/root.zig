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
pub const primitives = @import("lang/primitives.zig");
pub const symbols = @import("lang/symbols.zig");
pub const types = @import("lang/types.zig");

// The stages, in pipeline order. Each is a facade over a private subdirectory.
pub const parse = @import("parse.zig");
pub const tql_to_core = @import("tql_to_core.zig");
pub const type_check = @import("type_check.zig");
pub const simplify = @import("simplify.zig");
pub const core_to_stg = @import("core_to_stg.zig");

const grammar = @import("lang/grammar.zig");
const pcre2 = @import("regex.zig");

/// The prelude, linked beneath every query.
pub const prelude_source = tql_to_core.prelude_source;

// IMPROVE: don't export this
pub const ds = @import("ds.zig");
pub const Parser = parse.Parser;
pub const Grammar = grammar.Grammar;
pub const GrammarRegistry = grammar.Registry;

pub const Config = struct {
    allocator: Allocator,
    // Do I really need this?
    io: std.Io,
};

/// Force a `[a]` spine into its elements, appending them to `out`. Elements
/// are left unforced, so the caller decides what to force and when.
///
/// Diverges on an infinite list.
fn listElements(
    machine: *core_to_stg.Machine,
    gpa: Allocator,
    head: core_to_stg.Value,
    out: *std.ArrayList(*core_to_stg.Thunk),
) !void {
    const nil_tag = machine.datatypes.nilConstructor().tag;
    var current = head;
    while (true) {
        const constructed = switch (current) {
            .constructed => |c| c,
            else => return error.TypeError,
        };
        if (constructed.tag == nil_tag) return;
        if (constructed.len != 2) return error.TypeError;
        const fields = constructed.fields();
        try out.append(gpa, fields[0]);
        current = try machine.force(fields[1]);
    }
}

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
    ) !tql_to_core.Program {
        var parsed = try self.tql_parser.parseCollecting(query_source);
        defer parsed.deinit();
        if (parsed.hasErrors()) {
            for (parsed.diagnostics) |d| {
                try sink.report(d.category, d.span, "{s}", .{d.message});
            }
            return error.DesugarFailed;
        }

        var desugarer = try tql_to_core.Desugarer.init(self.config.allocator);
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
        desugarer: *tql_to_core.Desugarer,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        var parsed = try self.tql_parser.parseCollecting(prelude_source);
        defer parsed.deinit();
        // Compiled in, so a parse error here is a bug in this repository.
        std.debug.assert(!parsed.hasErrors());

        try desugarer.add(parsed.source_file, g, sink);
    }

    /// Parse, check, translate and run a query against a target file, writing
    /// its outputs as JSON.
    ///
    /// `target_path` is what `filename` yields; a query run on text with no
    /// path gets no output from it. Caller owns the returned JSON.
    ///
    /// The parsed target outlives the run: every node value points into it,
    /// and serialization forces thunks after the outputs are collected.
    pub fn evaluateQuery(
        self: *Engine,
        query_source: []const u8,
        target_source: []const u8,
        target_path: ?[]const u8,
        g: *const Grammar,
        sink: *diagnostic.Sink,
        result_allocator: Allocator,
    ) ![]const u8 {
        var compiled = try self.compileQuery(query_source, g, sink);
        defer compiled.deinit();

        var arena: std.heap.ArenaAllocator = .init(self.config.allocator);
        defer arena.deinit();

        const outcome = try compiled.run(
            target_source,
            target_path,
            result_allocator,
            arena.allocator(),
        );
        return outcome.json;
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
        var checked = try self.checkQuery(query_source, g, sink);
        errdefer checked.deinit();

        try simplify.run(&checked.program);

        const translated = try core_to_stg.translate(self.config.allocator, &checked.program);
        return .{
            .checked = checked,
            .translated = translated,
            .grammar = g,
            .allocator = self.config.allocator,
            .io = self.config.io,
        };
    }
};

/// A query checked and translated once, run against many targets.
pub const CompiledQuery = struct {
    checked: CheckedQuery,
    translated: core_to_stg.Program,
    grammar: *const Grammar,
    allocator: Allocator,
    io: std.Io,

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

        const query_start = std.Io.Timestamp.now(self.io, .real);

        var machine = try core_to_stg.Machine.init(
            scratch,
            self.allocator,
            &self.translated,
            &self.checked.program,
        );
        defer machine.deinit(self.allocator);
        machine.target = .{ .source = target, .path = target_path };

        const entry = machine.globals.get(self.checked.program.entry) orelse
            return error.MissingEntry;

        var root: core_to_stg.Thunk = core_to_stg.Thunk.value(.{ .node = .{ .inner = tree.rootNode() } });
        const outputs = try machine.apply(try machine.force(entry), &.{&root});

        var elements: std.ArrayList(*core_to_stg.Thunk) = .empty;
        defer elements.deinit(scratch);
        try listElements(&machine, scratch, outputs, &elements);

        // Serialized here, while the tree is alive. A node value borrows it,
        // so it cannot outlive this call.
        var w: std.Io.Writer.Allocating = .init(result_allocator);
        errdefer w.deinit();
        var jws = std.json.Stringify{ .writer = &w.writer };
        try jws.beginArray();
        for (elements.items) |element| {
            try machine.serialize(try machine.force(element), &jws);
        }
        try jws.endArray();

        const query_time = query_start.untilNow(self.io, .real);

        return .{
            .json = try w.toOwnedSlice(),
            .count = elements.items.len,
            .parse_time = parse_time,
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

/// A linked program and its inferred schemes. The two are created together and
/// destroyed together.
pub const CheckedQuery = struct {
    program: tql_to_core.Program,
    checked: type_check.Checked,

    pub fn deinit(self: *CheckedQuery) void {
        self.checked.deinit();
        self.program.deinit();
    }
};

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@This());
    refAllDecls(pcre2);
    refAllDecls(cst);
    refAllDecls(diagnostic);
    refAllDecls(parse);
    refAllDecls(grammar);
    refAllDecls(core);
    refAllDecls(tql_to_core);
    refAllDecls(symbols);
    refAllDecls(primitives);
    refAllDecls(types);
    refAllDecls(type_check);
    refAllDecls(core_to_stg);
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
    const text = program.interner.lookup("text").?;
    try std.testing.expect(program.primitives.contains(text));
    try std.testing.expectEqual(null, program.synthesis.get(text));
    try std.testing.expect(!program.primitives.contains(kind));
}

test "a constructor field that is not an atom becomes a thunk" {
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

    var translated = try core_to_stg.translate(allocator, &program);
    defer translated.deinit();

    // `append`'s `Cons h (append t ys)`. The recursive call is a compound
    // argument, so it must be let-bound to a thunk before the `Cons` rather
    // than evaluated into the field. This is what `laziness/005` depends on.
    const append = program.interner.lookup("append").?;
    var body: ?*const core_to_stg.Closure = null;
    for (translated.definitions) |definition| {
        if (definition.symbol == append) body = definition.value;
    }

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    const printer: core_to_stg.Printer = .{ .interner = &program.interner };
    try printer.closure(body.?, &w.writer);

    // The recursive call is let-bound to a thunk and the `Cons` takes that
    // binder as an atom, so an evaluator cannot force the field early. The
    // binder's number counts prelude binders allocated before `append` and is
    // not what this asserts.
    const printed = w.written();
    const let_open = "-> let { ";
    const thunk_start = std.mem.indexOf(u8, printed, let_open).? + let_open.len;
    const outer = printed[thunk_start..std.mem.indexOfScalarPos(u8, printed, thunk_start, ' ').?];
    const inner_open = std.mem.indexOfPos(u8, printed, thunk_start, let_open).? + let_open.len;
    const inner = printed[inner_open..std.mem.indexOfScalarPos(u8, printed, inner_open, ' ').?];

    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    try expected.writer.print(
        "{{}} \\u {{}} -> let {{ {s} = {{}} \\n {{xs,ys}} -> case xs of " ++
            "{{ Nil -> ys; Cons h t -> let {{ {s} = {{t,ys}} \\u {{}} -> append t ys }} " ++
            "in Cons h {s} }} }} in {s}",
        .{ outer, inner, inner, outer },
    );
    try std.testing.expectEqualStrings(expected.written(), printed);
}

test "a stream bind translates to a flat_map call" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery(
        \\main root = do { c <- children root; pure (kind c) c };
    , g, &sink);
    defer program.deinit();

    var translated = try core_to_stg.translate(allocator, &program);
    defer translated.deinit();

    var body: ?*const core_to_stg.Closure = null;
    for (translated.definitions) |definition| {
        if (definition.symbol == program.entry) body = definition.value;
    }

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    const printer: core_to_stg.Printer = .{ .interner = &program.interner };
    try printer.closure(body.?, &w.writer);

    // `bind` is not a machine form: the receiver becomes a one-argument
    // closure and the whole thing is an ordinary call to the prelude.
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "flat_map ") != null);
}

test "the evaluator runs the prelude's append" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    // Lists are built from the constructors directly: `collect` is a
    // primitive, and primitives are Stage 4's next step rather than this one.
    var program = try engine.desugarQuery(
        \\main root = append (Cons 1 Nil) (Cons 2 Nil);
    , g, &sink);
    defer program.deinit();

    var translated = try core_to_stg.translate(allocator, &program);
    defer translated.deinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var machine = try core_to_stg.Machine.init(arena.allocator(), allocator, &translated, &program);
    defer machine.deinit(allocator);

    const entry = machine.globals.get(program.entry).?;
    const main_value = try machine.force(entry);

    // `main` takes the root, which nothing here reads, so any thunk does.
    var unit: core_to_stg.Thunk = core_to_stg.Thunk.value(.{ .number = 0 });
    const applied = try machine.apply(main_value, &.{&unit});

    var elements: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer elements.deinit(arena.allocator());
    try listElements(&machine, arena.allocator(), applied, &elements);

    try std.testing.expectEqual(2, elements.items.len);
    try std.testing.expectEqual(@as(i64, 1), (try machine.force(elements.items[0])).number);
    try std.testing.expectEqual(@as(i64, 2), (try machine.force(elements.items[1])).number);
}

/// Runs `main` against a root the query does not read, and returns its
/// outputs. The tree primitives are Stage 5's, so nothing here parses a source.
fn runQuery(
    allocator: std.mem.Allocator,
    source: []const u8,
    arena: *std.heap.ArenaAllocator,
    out: *std.ArrayList(*core_to_stg.Thunk),
) !void {
    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery(source, g, &sink);
    defer program.deinit();

    var translated = try core_to_stg.translate(allocator, &program);
    defer translated.deinit();

    var machine = try core_to_stg.Machine.init(arena.allocator(), allocator, &translated, &program);
    defer machine.deinit(allocator);

    const main_value = try machine.force(machine.globals.get(program.entry).?);
    var unit: core_to_stg.Thunk = core_to_stg.Thunk.value(.{ .number = 0 });
    try listElements(
        &machine,
        arena.allocator(),
        try machine.apply(main_value, &.{&unit}),
        out,
    );

    // Forced here, while the machine is alive.
    for (out.items) |thunk| _ = try machine.force(thunk);
}

test "the evaluator runs pure, compose and the scalar operators" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `pure` builds a one-element list, the operator is scalar under Q16, and
    // `compose` is the pipe.
    try runQuery(allocator, "main root = (pure 1 | lift (\\n -> n + 2)) root;", &arena, &out);

    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqual(@as(i64, 3), out.items[0].state.evaluated.number);
}

test "the evaluator orders ints and strings" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `Ord` holds for `Int` and `String` only, and `<=`/`>=` are the two that
    // an `== .lt` reading would get wrong on equal operands.
    try runQuery(allocator,
        \\main root =
        \\  (pure (1 < 2), pure (2 <= 2), pure (2 > 1), pure (1 >= 2),
        \\   pure ("a" < "b"), pure ("b" <= "a")) root;
    , &arena, &out);

    try std.testing.expectEqual(6, out.items.len);
    const expected = [_]u32{ 1, 1, 1, 0, 1, 0 };
    for (out.items, expected) |thunk, tag| {
        try std.testing.expectEqual(tag, thunk.state.evaluated.constructed.tag);
    }
}

test "the evaluator runs lift and select" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `select` keeps the inputs its predicate accepts. `lift` carries the
    // scalar predicate into filter position.
    try runQuery(allocator,
        \\main root = ((pure 1, pure 2, pure 3) | select (lift (\n -> n > 1))) root;
    , &arena, &out);

    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqual(@as(i64, 2), out.items[0].state.evaluated.number);
    try std.testing.expectEqual(@as(i64, 3), out.items[1].state.evaluated.number);
}

test "the evaluator runs exists, any and all" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `all` over an empty source is vacuously true, and its arms must be in
    // the right order: swapped, this yields false.
    try runQuery(allocator,
        \\main root =
        \\  (exists (pure 1),
        \\   exists empty,
        \\   any (pure 1, pure 2) (lift (\n -> n > 1)),
        \\   any (pure 1) (lift (\n -> n > 1)),
        \\   all (pure 2, pure 3) (lift (\n -> n > 1)),
        \\   all (pure 1, pure 2) (lift (\n -> n > 1)),
        \\   all empty (lift (\n -> n > 1))) root;
    , &arena, &out);

    try std.testing.expectEqual(7, out.items.len);
    const expected = [_]u32{ 1, 0, 1, 0, 1, 0, 1 };
    for (out.items, expected) |thunk, tag| {
        try std.testing.expectEqual(tag, thunk.state.evaluated.constructed.tag);
    }
}

test "the evaluator runs or_else" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // The fallback runs only when the primary yields nothing.
    try runQuery(allocator,
        \\main root = (or_else (pure 1) (pure 2), or_else empty (pure 3)) root;
    , &arena, &out);

    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqual(@as(i64, 1), out.items[0].state.evaluated.number);
    try std.testing.expectEqual(@as(i64, 3), out.items[1].state.evaluated.number);
}

test "a filter chain over a long list runs in bounded stack" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `count` builds a list of `n` elements and `compose` runs a filter over
    // it that keeps none, so reaching the end walks a chain of `append Nil`.
    // Every step of that walk is a tail call: at 3000 elements this overflows
    // a 16 MiB stack unless the evaluator loops rather than recurses.
    try runQuery(allocator,
        \\count n = if n <= 0 then Nil else Cons n (count (n - 1));
        \\keep_none x = Nil;
        \\main root = flat_map (count 3000) keep_none;
    , &arena, &out);

    try std.testing.expectEqual(0, out.items.len);
}

test "the evaluator runs probe without forcing the whole stream" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*core_to_stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `laziness/005`: the left operand satisfies the probe, so the infinite
    // right operand is never forced. This is the fixture the thunk-per-field
    // obligation exists for.
    try runQuery(allocator,
        \\from n = pure n, from (n + 1);
        \\main root = probe (pure 0, from 1) root;
    , &arena, &out);

    try std.testing.expectEqual(1, out.items.len);
    // `True` is tag 1.
    try std.testing.expectEqual(1, out.items[0].state.evaluated.constructed.tag);
}

test "forcing a global cycle reports it rather than hanging" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    // `laziness/011`: `a` and `b` both resolve, and forcing either re-enters
    // an `evaluating` thunk with no lambda between. The black hole is what
    // turns that from a hang into an answer.
    var program = try engine.desugarQuery(
        \\a = b;
        \\b = a;
        \\main root = a;
    , g, &sink);
    defer program.deinit();

    var translated = try core_to_stg.translate(allocator, &program);
    defer translated.deinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var machine = try core_to_stg.Machine.init(arena.allocator(), allocator, &translated, &program);
    defer machine.deinit(allocator);

    const a = program.interner.lookup("a").?;
    try std.testing.expectError(error.Cycle, machine.force(machine.globals.get(a).?));
}

test "isLocal separates locals from globals in a real program" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery("main root = pure 1 root;", g, &sink);
    defer program.deinit();

    const translate_mod = @import("core_to_stg/translate.zig");
    var translator: translate_mod.Translator = .{
        .arena = allocator,
        .gpa = allocator,
        .program = &program,
        .interner = &program.interner,
    };

    // Reached by identity: never captured.
    try std.testing.expect(!translate_mod.Translator.isLocal(&translator, program.interner.lookup("Cons").?));
    try std.testing.expect(!translate_mod.Translator.isLocal(&translator, program.interner.lookup("compose").?));
    try std.testing.expect(!translate_mod.Translator.isLocal(&translator, program.interner.lookup("append").?));

    // A synthesized primitive is reached by identity like any other.
    {
        var ops = try engine.desugarQuery("main root = pure (1 + 2) root;", g, &sink);
        defer ops.deinit();
        var t2: translate_mod.Translator = .{
            .arena = allocator,
            .gpa = allocator,
            .program = &ops,
            .interner = &ops.interner,
        };
        const plus = ops.interner.lookup("op[+]").?;
        try std.testing.expect(!translate_mod.Translator.isLocal(&t2, plus));
    }

    // A binder is a local, and is what a closure must capture.
    const append_body = for (program.definitions) |definition| {
        if (definition.symbol == program.interner.lookup("append").?) break definition.body;
    } else unreachable;
    const xs = append_body.kind.lambda.parameter;
    try std.testing.expect(translate_mod.Translator.isLocal(&translator, xs));
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
        \\identity = \x -> Cons x Nil
        \\pure = \v -> \x -> Cons v Nil
        \\empty = \x -> Nil
        \\unnest = \xs -> xs
        \\append = \xs -> \ys -> case xs of { Nil -> ys; Cons h t -> Cons h (append t ys) }
        \\flat_map = \xs -> \f -> case xs of { Nil -> Nil; Cons h t -> append (f h) (flat_map t f) }
        \\compose = \p -> \q -> \x -> flat_map (p x) q
        \\probe = \p -> \x -> case p x of { Nil -> Cons False Nil; Cons h t -> Cons True Nil }
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
        \\identity : a -> [a]
        \\pure : a -> b -> [a]
        \\empty : a -> [b]
        \\unnest : [a] -> [a]
        \\append : [a] -> [a] -> [a]
        \\flat_map : [a] -> (a -> [b]) -> [b]
        \\compose : (a -> [b]) -> (b -> [c]) -> a -> [c]
        \\probe : (a -> [b]) -> a -> [Bool]
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
