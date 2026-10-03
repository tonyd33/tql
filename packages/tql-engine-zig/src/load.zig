//! Finds the modules a query imports and adds them to a link, each after the
//! modules it imports.

const std = @import("std");
const cst = @import("lang/cst.zig");
const diagnostic = @import("diagnostic.zig");
const grammar = @import("lang/grammar.zig");
const parse = @import("parse.zig");
const tql_to_core = @import("tql_to_core.zig");
const core = @import("core.zig");

const prelude_name = core.ModuleId.prelude_name;

/// Where module sources come from.
pub const Loader = struct {
    context: *anyopaque,
    loadFn: *const fn (context: *anyopaque, name: []const u8) Loaded,

    /// The source of the module named `name`. A found source must outlive the
    /// compilation; a failure's message must outlive the call.
    pub fn load(self: Loader, name: []const u8) Loaded {
        return self.loadFn(self.context, name);
    }
};

pub const Loaded = union(enum) {
    missing,
    found: diagnostic.Source,
    /// The module exists but cannot be read, for the reason given.
    failed: []const u8,
};

/// A module shipped inside the engine, found by name in every host.
pub const Bundled = struct {
    name: []const u8,
    /// How diagnostics name it.
    path: []const u8,
    text: []const u8,
};

/// Serves bundled modules by name.
pub const BundledLoader = struct {
    modules: []const Bundled,

    pub fn loader(self: *BundledLoader) Loader {
        return .{ .context = self, .loadFn = load };
    }

    fn load(context: *anyopaque, name: []const u8) Loaded {
        const self: *BundledLoader = @ptrCast(@alignCast(context));
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return .{ .found = .{ .name = m.path, .text = m.text } };
        }
        return .missing;
    }
};

const Error = error{ OutOfMemory, ParseFailed, WriteFailed };

/// A parsed module waiting to be added.
const Module = struct {
    source: cst.SourceFile,
    /// Null for the entry, whose parse the caller owns.
    parsed: ?parse.ParseResult,

    /// Null for an entry without a header, which no import can name.
    fn name(self: Module) ?[]const u8 {
        return if (self.source.header) |h| h.name else null;
    }

    /// The grammars a `for` clause names, or null for a grammar-generic
    /// module.
    fn grammars(self: Module) ?[]const []const u8 {
        return if (self.source.header) |h| h.grammars else null;
    }
};

/// The modules an entry imports, directly or not, in dependency order.
pub const Graph = struct {
    gpa: std.mem.Allocator,
    parser: *parse.Parser,
    /// Asked in turn; a module more than one finds is ambiguous.
    loaders: []const Loader,
    sources: *diagnostic.Sources,
    /// Each module after every module it imports, the entry last.
    order: std.ArrayList(Module) = .empty,
    /// The import chain from the entry to the module being visited.
    path: std.ArrayList(?[]const u8) = .empty,
    /// Every module named so far, loaded or rejected, and the prelude.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Graph) void {
        for (self.order.items) |*m| {
            if (m.parsed) |*p| p.deinit();
        }
        self.order.deinit(self.gpa);
        self.path.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    /// Loads everything `entry` imports. Every problem found is reported;
    /// the graph is complete only when `sink` stays empty.
    pub fn visitEntry(self: *Graph, entry: cst.SourceFile, sink: *diagnostic.Sink) !void {
        try self.seen.put(self.gpa, prelude_name, {});
        try self.visit(.{ .source = entry, .parsed = null }, sink);
    }

    fn visit(self: *Graph, module: Module, sink: *diagnostic.Sink) Error!void {
        try self.path.append(self.gpa, module.name());
        for (module.source.imports) |import| {
            if (self.onPath(import.module)) |start| {
                try self.reportCycle(start, import, sink);
                continue;
            }
            if (self.seen.contains(import.module)) continue;
            try self.seen.put(self.gpa, import.module, {});
            try self.load(import, sink);
        }
        _ = self.path.pop();
        try self.order.append(self.gpa, module);
    }

    fn load(self: *Graph, import: cst.Import, sink: *diagnostic.Sink) Error!void {
        var found: ?diagnostic.Source = null;
        for (self.loaders) |l| switch (l.load(import.module)) {
            .missing => {},
            .failed => |reason| return try sink.report(
                .unreadable_module,
                import.span,
                "`{s}` cannot be read: {s}",
                .{ import.module, reason },
            ),
            .found => |source| {
                if (found) |earlier| return try sink.report(
                    .ambiguous_module,
                    import.span,
                    "`{s}` is found as both `{s}` and `{s}`",
                    .{ import.module, earlier.name orelse import.module, source.name orelse import.module },
                );
                found = source;
            },
        };
        const source = found orelse {
            return try sink.report(.unresolved_module, import.span, "no module is named `{s}`", .{import.module});
        };
        const id = try self.sources.add(source);
        var parsed = try self.parser.parseCollecting(source.text, id);
        var owned = true;
        defer if (owned) parsed.deinit();

        if (parsed.hasErrors()) return try sink.extend(parsed.diagnostics);
        const header = parsed.source_file.header orelse {
            return try sink.report(
                .module_name_mismatch,
                import.span,
                "`{s}` has no `module {s};` header",
                .{ import.module, import.module },
            );
        };
        if (!std.mem.eql(u8, header.name, import.module)) {
            return try sink.report(
                .module_name_mismatch,
                header.span,
                "this module is imported as `{s}`",
                .{import.module},
            );
        }
        owned = false;
        try self.visit(.{ .source = parsed.source_file, .parsed = parsed }, sink);
    }

    fn reportCycle(self: *Graph, start: usize, import: cst.Import, sink: *diagnostic.Sink) !void {
        var chain: std.Io.Writer.Allocating = .init(self.gpa);
        defer chain.deinit();
        for (self.path.items[start..]) |name| try chain.writer.print("`{s}` imports ", .{name.?});
        try chain.writer.print("`{s}`", .{import.module});
        try sink.report(.import_cycle, import.span, "imports form a cycle: {s}", .{chain.written()});
    }

    fn onPath(self: *const Graph, name: []const u8) ?usize {
        for (self.path.items, 0..) |on, i| {
            if (std.mem.eql(u8, on orelse continue, name)) return i;
        }
        return null;
    }

    /// Reports an entry whose `for` clause leaves out `g`, and each import of
    /// a module not written for every grammar the importer is. An entry
    /// without a `for` clause is written for `g`; any other module without one
    /// imports only modules without one.
    pub fn checkGrammars(self: *const Graph, g: *const grammar.Grammar, sink: *diagnostic.Sink) !void {
        const entry = self.order.items[self.order.items.len - 1];
        if (entry.grammars()) |declared| {
            if (!contains(declared, g.name)) {
                try sink.report(
                    .grammar_mismatch,
                    entry.source.header.?.span,
                    "this query is not written for `{s}`",
                    .{g.name},
                );
            }
        }
        const run = [1][]const u8{g.name};
        for (self.order.items, 0..) |m, index| {
            const written_for = self.required(index, &run);
            for (m.source.imports) |import| {
                const imported = self.named(import.module) orelse continue;
                const provided = imported.grammars() orelse continue;
                const wanted = written_for orelse {
                    try sink.report(
                        .grammar_mismatch,
                        import.span,
                        "`{s}` has a `for` clause, so a module without one cannot import it",
                        .{import.module},
                    );
                    continue;
                };
                for (wanted) |grammar_name| {
                    if (contains(provided, grammar_name)) continue;
                    try reportUnwritten(import, grammar_name, sink);
                    break;
                }
            }
        }
    }

    /// The grammars `order[index]` is written for: its `for` clause, or `run`
    /// for an entry without one. Null for a grammar-generic module.
    fn required(self: *const Graph, index: usize, run: *const [1][]const u8) ?[]const []const u8 {
        if (self.order.items[index].grammars()) |declared| return declared;
        return if (index == self.order.items.len - 1) run else null;
    }

    fn reportUnwritten(import: cst.Import, wanted: []const u8, sink: *diagnostic.Sink) !void {
        try sink.report(
            .grammar_mismatch,
            import.span,
            "`{s}` is not written for `{s}`",
            .{ import.module, wanted },
        );
    }

    fn named(self: *const Graph, name: []const u8) ?Module {
        for (self.order.items) |m| {
            if (std.mem.eql(u8, m.name() orelse continue, name)) return m;
        }
        return null;
    }

    /// Adds every module to `desugarer` in dependency order. A grammar-generic
    /// module is desugared with no grammar.
    ///
    /// Preconditions:
    /// - `visitEntry` and `checkGrammars` reported nothing.
    pub fn link(
        self: *const Graph,
        desugarer: *tql_to_core.Desugarer,
        g: *const grammar.Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        var ids: std.StringHashMapUnmanaged(core.ModuleId) = .empty;
        defer ids.deinit(self.gpa);
        try ids.put(self.gpa, prelude_name, .prelude);
        var imports: std.ArrayList(tql_to_core.Import) = .empty;
        defer imports.deinit(self.gpa);

        const run = [1][]const u8{g.name};
        for (self.order.items, 0..) |m, index| {
            imports.clearRetainingCapacity();
            const explicit_prelude = for (m.source.imports) |i| {
                if (std.mem.eql(u8, i.module, prelude_name)) break true;
            } else false;
            if (!explicit_prelude) try imports.append(self.gpa, .{ .module = .prelude });
            for (m.source.imports) |i| {
                try imports.append(self.gpa, .{
                    .module = ids.get(i.module).?,
                    .qualifier = i.qualifier,
                    .selects = i.selects,
                });
            }

            const header = m.source.header;
            const id = try desugarer.declareModule(m.name() orelse "Main", if (header) |h| h.exports else .all);
            if (m.name()) |name| try ids.put(self.gpa, name, id);
            const generic = self.required(index, &run) == null;
            try desugarer.add(id, imports.items, m.source, if (generic) null else g, sink);
        }
    }
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}
