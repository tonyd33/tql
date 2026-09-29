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
    machine: *stg.Machine,
    gpa: Allocator,
    head: stg.Value,
    out: *std.ArrayList(*stg.Thunk),
) !void {
    const nil_tag = machine.program.structural.nil.tag;
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
    ) !core.Program {
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

        try type_check.check(self.config.allocator, &program, sink);
        return program;
    }

    /// Parses and desugars `prelude.tql` into the link.
    ///
    /// Recompiled per link: a module's `SymbolId`s index the registry it was
    /// desugared against, and a `:k` literal resolves its kind ID from the
    /// grammar, so a cached one would be valid only per grammar and per
    /// registry prefix.
    fn addPrelude(
        self: *Engine,
        desugarer: *tql_to_core.Desugarer,
        g: *const Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        var parsed = try self.tql_parser.parseCollecting(prelude_source);
        defer parsed.deinit();
        // Compiled in, so a parse error here is a bug in this repository.
        if (parsed.hasErrors()) return error.PreludeInvalid;

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

        try core_to_core.run(&checked);

        const translated = try core_to_stg.translate(self.config.allocator, &checked);
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
    checked: core.Program,
    translated: stg.Program,
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

        var machine = try stg.Machine.init(scratch, self.allocator, &self.translated);
        defer machine.deinit();
        machine.target = .{ .source = target, .path = target_path };

        const entry = machine.global(self.checked.entry) orelse
            return error.MissingEntry;

        const root = try scratch.create(stg.Thunk);
        root.* = stg.Thunk.value(.{ .node = .{ .inner = tree.rootNode() } });
        const outputs = try machine.apply(try machine.force(entry), &.{root});

        var elements: std.ArrayList(*stg.Thunk) = .empty;
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
    refAllDecls(core_to_stg);
    refAllDecls(stg);
    refAllDecls(inspect);
}

test "a field symbol carries the grammar id it resolved" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery(
        "main = children | of_kind :class_declaration | .name;",
        g,
        &sink,
    );
    defer program.deinit();

    const field = program.env.interner.lookup("field[name]").?;
    const field_what = program.env.interner.details(field).synthesized;
    try std.testing.expectEqualStrings("name", field_what.field.name);
    try std.testing.expectEqual(g.language.fieldIdForName("name"), field_what.field.id);

    // A primitive is not synthesized, and a synthesized symbol is not a primitive.
    const text = program.env.interner.lookup("text").?;
    try std.testing.expectEqual(core.PrimOp.text, program.env.interner.details(text).primop);
    try std.testing.expect(program.env.interner.details(field) == .synthesized);
}

test "a kind literal carries the grammar id it resolved" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var program = try engine.desugarQuery("main = is_kind :class_declaration;", g, &sink);
    defer program.deinit();

    const body = program.entryDefinitions()[0].body;
    const function = body.kind.apply.function.kind.symbol;
    try std.testing.expectEqual(core.PrimOp.is_kind, program.env.interner.details(function).primop);
    const kind = body.kind.apply.argument.kind.literal.kind;
    try std.testing.expectEqualStrings("class_declaration", kind.name);
    try std.testing.expectEqual(g.language.idForNodeKind("class_declaration", true), kind.id);
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
    const append = program.env.interner.lookup("append").?;
    var body: ?*const stg.Closure = null;
    for (translated.definitions) |definition| {
        if (definition.symbol == append) body = definition.value;
    }

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    const printer: stg.Printer = .{ .interner = &program.env.interner };
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

test "a stream bind translates to a concat_map call" {
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

    var body: ?*const stg.Closure = null;
    for (translated.definitions) |definition| {
        if (definition.symbol == program.entry) body = definition.value;
    }

    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    const printer: stg.Printer = .{ .interner = &program.env.interner };
    try printer.closure(body.?, &w.writer);

    // `bind` is not a machine form: the receiver becomes a one-argument
    // closure and the whole thing is an ordinary call to the prelude.
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "concat_map ") != null);
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

    var machine = try stg.Machine.init(arena.allocator(), allocator, &translated);
    defer machine.deinit();

    const entry = machine.global(program.entry).?;
    const main_value = try machine.force(entry);

    // `main` takes the root, which nothing here reads, so any thunk does.
    var unit: stg.Thunk = stg.Thunk.value(.{ .number = 0 });
    const applied = try machine.apply(main_value, &.{&unit});

    var elements: std.ArrayList(*stg.Thunk) = .empty;
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
    out: *std.ArrayList(*stg.Thunk),
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

    var machine = try stg.Machine.init(arena.allocator(), allocator, &translated);
    defer machine.deinit();

    const main_value = try machine.force(machine.global(program.entry).?);
    var unit: stg.Thunk = stg.Thunk.value(.{ .number = 0 });
    try listElements(
        &machine,
        arena.allocator(),
        try machine.apply(main_value, &.{&unit}),
        out,
    );

    // Forced here, while the machine is alive, and copied out: a literal's
    // thunk belongs to the translated program, freed on return.
    for (out.items) |*thunk| {
        _ = try machine.force(thunk.*);
        const copy = try arena.allocator().create(stg.Thunk);
        copy.* = thunk.*.*;
        thunk.* = copy;
    }
}

test "the evaluator runs pure, kleisli and the scalar operators" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `pure` builds a one-element list, the operator is scalar under Q16, and
    // `compose` is the pipe.
    try runQuery(allocator, "main root = (pure 1 | arr (\\n -> n + 2)) root;", &arena, &out);

    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqual(@as(i64, 3), out.items[0].state.evaluated.number);
}

test "the evaluator orders ints and strings" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `Ord` holds for `Int` and `String` only, and `<=`/`>=` are the two that
    // an `== .lt` reading would get wrong on equal operands.
    try runQuery(allocator,
        \\main root =
        \\  const [1 < 2, 2 <= 2, 2 > 1, 1 >= 2, "a" < "b", "b" <= "a"] root;
    , &arena, &out);

    try std.testing.expectEqual(6, out.items.len);
    const expected = [_]u32{ 1, 1, 1, 0, 1, 0 };
    for (out.items, expected) |thunk, tag| {
        try std.testing.expectEqual(tag, thunk.state.evaluated.constructed.tag);
    }
}

test "the evaluator runs keep" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    try runQuery(allocator,
        \\main root = (const [1, 2, 3] | keep (\n -> n > 1)) root;
    , &arena, &out);

    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqual(@as(i64, 2), out.items[0].state.evaluated.number);
    try std.testing.expectEqual(@as(i64, 3), out.items[1].state.evaluated.number);
}

test "the evaluator runs has" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    try runQuery(allocator,
        \\main root = const [
        \\  has (pure 1) root,
        \\  has none root,
        \\  has (const [1, 2] | keep (\n -> n > 1)) root,
        \\  has (pure 1 | keep (\n -> n > 1)) root
        \\] root;
    , &arena, &out);

    try std.testing.expectEqual(4, out.items.len);
    const expected = [_]u32{ 1, 0, 1, 0 };
    for (out.items, expected) |thunk, tag| {
        try std.testing.expectEqual(tag, thunk.state.evaluated.constructed.tag);
    }
}

test "the evaluator runs or_else" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // The fallback runs only when the primary yields nothing.
    try runQuery(allocator,
        \\main root = (or_else (pure 1) (pure 2) <|> or_else none (pure 3)) root;
    , &arena, &out);

    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqual(@as(i64, 1), out.items[0].state.evaluated.number);
    try std.testing.expectEqual(@as(i64, 3), out.items[1].state.evaluated.number);
}

test "a filter chain over a long list runs in bounded stack" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `count` builds a list of `n` elements and `concat_map` runs a filter
    // over it that keeps none, so reaching the end walks a chain of `append
    // Nil`.
    // Every step of that walk is a tail call: at 3000 elements this overflows
    // a 16 MiB stack unless the evaluator loops rather than recurses.
    try runQuery(allocator,
        \\count n = if n <= 0 then Nil else Cons n (count (n - 1));
        \\keep_none x = Nil;
        \\main root = concat_map keep_none (count 3000);
    , &arena, &out);

    try std.testing.expectEqual(0, out.items.len);
}

test "a tail call through an over-applied callee runs in bounded stack" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `compose loop identity` takes three arguments and is given four, so
    // every iteration's tail call is over-applied. `acc < 0` forces the
    // accumulator, so no thunk chain builds up behind it.
    try runQuery(allocator,
        \\loop n acc =
        \\  if n <= 0 then acc
        \\  else if acc < 0 then 0
        \\  else compose loop identity (n - 1) (acc + 1);
        \\main root = pure (loop 20000 0) root;
    , &arena, &out);

    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqual(20000, out.items[0].state.evaluated.number);
}

test "equality on long lists runs in bounded stack" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    try runQuery(allocator,
        \\count n = if n <= 0 then Nil else Cons n (count (n - 1));
        \\main root = pure (count 20000 = count 20000) root;
    , &arena, &out);

    try std.testing.expectEqual(1, out.items.len);
    // `True` is tag 1.
    try std.testing.expectEqual(1, out.items[0].state.evaluated.constructed.tag);
}

test "recursion deeper than the stack budget stops with an error" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `n + sum (n - 1)` forces the recursive call before adding, so each level
    // holds a native frame.
    try std.testing.expectError(error.StackOverflow, runQuery(allocator,
        \\sum n = if n <= 0 then 0 else n + sum (n - 1);
        \\main root = pure (sum 1000000) root;
    , &arena, &out));
}

test "the evaluator runs has without forcing the whole stream" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var out: std.ArrayList(*stg.Thunk) = .empty;
    defer out.deinit(arena.allocator());

    // `laziness/005`: the left operand satisfies `has`, so the infinite
    // right operand is never forced. This is the fixture the thunk-per-field
    // obligation exists for.
    try runQuery(allocator,
        \\from n = pure n <|> from (n + 1);
        \\main root = pure (has (pure 0 <|> from 1) root) root;
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

    var machine = try stg.Machine.init(arena.allocator(), allocator, &translated);
    defer machine.deinit();

    const a = program.env.interner.lookup("a").?;
    try std.testing.expectError(error.Cycle, machine.force(machine.global(a).?));
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

    var translator = try core_to_stg.Translator.init(allocator, allocator, &program);
    defer translator.deinit();

    const isLocal = core_to_stg.Translator.isLocal;

    // Reached by identity: never captured.
    try std.testing.expect(!isLocal(&translator, program.env.interner.lookup("Cons").?));
    try std.testing.expect(!isLocal(&translator, program.env.interner.lookup("kleisli").?));
    try std.testing.expect(!isLocal(&translator, program.env.interner.lookup("append").?));

    // A synthesized primitive is reached by identity like any other.
    {
        var ops = try engine.desugarQuery("main root = pure (1 + 2) root;", g, &sink);
        defer ops.deinit();
        var t2 = try core_to_stg.Translator.init(allocator, allocator, &ops);
        defer t2.deinit();
        const plus = ops.env.interner.lookup("op[+]").?;
        try std.testing.expect(!isLocal(&t2, plus));
    }

    // A binder is a local, and is what a closure must capture.
    const append_body = for (program.definitions) |definition| {
        if (definition.symbol == program.env.interner.lookup("append").?) break definition.body;
    } else return error.TestUnexpectedResult;
    const xs = append_body.kind.lambda.parameter;
    try std.testing.expect(isLocal(&translator, xs));
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
    const printer: core.Printer = .{ .interner = &program.env.interner };
    for (program.definitions[0..program.entry_offset], 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} = ", .{program.env.interner.spelling(definition.symbol)});
        try printer.term(definition.body, &w.writer);
    }

    try std.testing.expectEqualStrings(
        \\identity = \x -> x
        \\const = \x -> \y -> x
        \\compose = \f -> \g -> \x -> f (g x)
        \\flip = \f -> \x -> \y -> f y x
        \\null = \xs -> case xs of { Nil -> True; Cons h t -> False }
        \\append = \xs -> \ys -> case xs of { Nil -> ys; Cons h t -> Cons h (append t ys) }
        \\concat = \xss -> case xss of { Nil -> Nil; Cons h t -> append h (concat t) }
        \\map = \f -> \xs -> case xs of { Nil -> Nil; Cons h t -> Cons (f h) (map f t) }
        \\concat_map = \f -> \xs -> case xs of { Nil -> Nil; Cons h t -> append (f h) (concat_map f t) }
        \\filter = \p -> \xs -> case xs of { Nil -> Nil; Cons h t -> case p h of { False -> filter p t; True -> Cons h (filter p t) } }
        \\foldr = \f -> \z -> \xs -> case xs of { Nil -> z; Cons h t -> f h (foldr f z t) }
        \\not = \b -> case b of { False -> True; True -> False }
        \\and = \a -> \b -> case a of { False -> False; True -> b }
        \\or = \a -> \b -> case a of { False -> b; True -> True }
        \\any = \p -> \xs -> case xs of { Nil -> False; Cons h t -> or (p h) (any p t) }
        \\all = \p -> \xs -> case xs of { Nil -> True; Cons h t -> and (p h) (all p t) }
        \\guard = \b -> case b of { False -> Nil; True -> Cons Unit Nil }
        \\return = \a -> Cons a Nil
        \\take = \n -> \xs -> case op[<=] n 0 of { False -> case xs of { Nil -> Nil; Cons h t -> Cons h (take (op[-] n 1) t) }; True -> Nil }
        \\drop = \n -> \xs -> case op[<=] n 0 of { False -> case xs of { Nil -> Nil; Cons h t -> drop (op[-] n 1) t }; True -> xs }
        \\head = \xs -> take 1 xs
        \\tail = \xs -> drop 1 xs
        \\pure = \v -> \x -> Cons v Nil
        \\none = \x -> Nil
        \\kleisli = \p -> \q -> \x -> concat_map q (p x)
        \\alt = \p -> \q -> \x -> append (p x) (q x)
        \\arr = \f -> \x -> Cons (f x) Nil
        \\collect = \p -> \x -> Cons (p x) Nil
        \\keep = \p -> \x -> case p x of { False -> Nil; True -> Cons x Nil }
        \\has = \p -> \x -> not (null (p x))
        \\first = \p -> \x -> head (p x)
        \\or_else = \primary -> \fallback -> \x -> case primary x of { Nil -> fallback x; Cons h t -> Cons h t }
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

    for (result.definitions[0..result.entry_offset], 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} : ", .{result.env.interner.spelling(definition.symbol)});
        try result.env.schemeOf(definition.symbol).?.format(&w.writer);
    }

    try std.testing.expectEqualStrings(
        \\identity : a -> a
        \\const : a -> b -> a
        \\compose : (a -> b) -> (c -> a) -> c -> b
        \\flip : (a -> b -> c) -> b -> a -> c
        \\null : [a] -> Bool
        \\append : [a] -> [a] -> [a]
        \\concat : [[a]] -> [a]
        \\map : (a -> b) -> [a] -> [b]
        \\concat_map : (a -> [b]) -> [a] -> [b]
        \\filter : (a -> Bool) -> [a] -> [a]
        \\foldr : (a -> b -> b) -> b -> [a] -> b
        \\not : Bool -> Bool
        \\and : Bool -> Bool -> Bool
        \\or : Bool -> Bool -> Bool
        \\any : (a -> Bool) -> [a] -> Bool
        \\all : (a -> Bool) -> [a] -> Bool
        \\guard : Bool -> [Unit]
        \\return : a -> [a]
        \\take : Int -> [a] -> [a]
        \\drop : Int -> [a] -> [a]
        \\head : [a] -> [a]
        \\tail : [a] -> [a]
        \\pure : a -> b -> [a]
        \\none : a -> [b]
        \\kleisli : (a -> [b]) -> (b -> [c]) -> a -> [c]
        \\alt : (a -> [b]) -> (a -> [b]) -> a -> [b]
        \\arr : (a -> b) -> a -> [b]
        \\collect : (a -> [b]) -> a -> [[b]]
        \\keep : (a -> Bool) -> a -> [a]
        \\has : (a -> [b]) -> a -> Bool
        \\first : (a -> [b]) -> a -> [b]
        \\or_else : (a -> [b]) -> (a -> [b]) -> a -> [b]
    , w.written());
}

fn expectTypeErrorMessage(query: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    try std.testing.expectError(error.TypeCheckFailed, engine.checkQuery(query, g, &sink));
    try std.testing.expectEqual(1, sink.items().len);
    try std.testing.expectEqualStrings(expected, sink.items()[0].message);
}

test "a type mismatch names its metavariables by letter" {
    try expectTypeErrorMessage(
        "main = children_of_kind :class_declaration | text;",
        "Expected `[a]`, found `String`.",
    );
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

    var program = try engine.desugarQuery("main = keep (has children);", g, &sink);
    defer program.deinit();

    try std.testing.expectEqualStrings("main", program.env.interner.spelling(program.entry));

    var seen_null = false;
    var seen_has = false;
    for (program.components) |component| {
        for (component) |index| {
            const spelling = program.env.interner.spelling(program.definitions[index].symbol);
            if (std.mem.eql(u8, spelling, "null")) seen_null = true;
            if (std.mem.eql(u8, spelling, "has")) {
                try std.testing.expect(seen_null);
                seen_has = true;
            }
            if (std.mem.eql(u8, spelling, "main")) try std.testing.expect(seen_has);
        }
    }
    try std.testing.expect(seen_has);
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

    for (result.entryDefinitions(), 0..) |definition, i| {
        if (i > 0) try w.writer.writeByte('\n');
        try w.writer.print("{s} : ", .{result.env.interner.spelling(definition.symbol)});
        try result.env.schemeOf(definition.symbol).?.format(&w.writer);
    }

    try std.testing.expectEqualStrings(
        \\or_default : Maybe a -> a -> a
        \\main : Node -> [Int]
    , w.written());
}

test "a structural type redeclared with the wrong shape is rejected" {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    // The evaluator builds `Bool` values directly, so the prelude's spelling
    // and tag order are the ones it assumes.
    try std.testing.expectError(error.DesugarFailed, engine.desugarQuery(
        \\type Bool = Maybe | Definitely;
        \\main = pure 1;
    , g, &sink));

    try std.testing.expect(sink.hasErrors());
}
