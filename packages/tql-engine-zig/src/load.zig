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
    loadFn: *const fn (context: *anyopaque, name: []const u8) ?diagnostic.Source,

    /// The source of the module named `name`, or null when there is none.
    /// The source must outlive the compilation.
    pub fn load(self: Loader, name: []const u8) ?diagnostic.Source {
        return self.loadFn(self.context, name);
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
};

/// The modules an entry imports, directly or not, in dependency order.
pub const Graph = struct {
    gpa: std.mem.Allocator,
    parser: *parse.Parser,
    loader: ?Loader,
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
        const loaded = if (self.loader) |l| l.load(import.module) else null;
        const source = loaded orelse {
            try sink.report(.unresolved_module, import.span, "no module is named `{s}`", .{import.module});
            return;
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

    /// Adds every module to `desugarer` in dependency order.
    ///
    /// Preconditions:
    /// - `visitEntry` reported nothing.
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

        for (self.order.items) |m| {
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
            try desugarer.add(id, imports.items, m.source, g, sink);
        }
    }
};
