//! Assembles desugared Core modules into a `Program`.
//!
//! Modules link in order, the entry module last. Definitions are concatenated
//! and each module's edges renumbered into linked indices before Tarjan runs once
//! over the merged graph. Per-module SCCs would hold only while no cycle
//! crosses a module boundary and modules arrive in dependency order; one
//! whole-program pass does not depend on either.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const grammar = @import("../lang/grammar.zig");
const annotation = @import("annotation.zig");
const resolve = @import("resolve.zig");
const desugar = @import("desugar.zig");
const builtin = @import("../builtin.zig");
const datatypes = core.datatypes;
const types = core.types;

pub const Error = error{LinkFailed} || std.mem.Allocator.Error;

/// A linked program: definitions, the SCCs type checking consumes, and the
/// entrypoint.
///
/// Terms and the strings they reference live in `arena`, which is heap-owned so
/// the program can be returned by value: an `ArenaAllocator`'s allocator holds
/// a pointer to the arena itself, which moving the struct would dangle.
pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    definitions: []const core.Definition,
    /// Indices into `definitions`, grouped by strongly connected component in
    /// dependency order.
    components: []const []const u32,
    /// The linked program's `main`.
    entry: core.SymbolId,
    /// Where the entry module's definitions begin; everything below it was
    /// linked in from a library module.
    entry_offset: u32,
    interner: core.Interner,
    primitives: builtin.Table,
    /// Declared types and their constructors, collected before any body was
    /// desugared so a constructor reference resolves like any other global.
    datatypes: datatypes.Registry,
    annotations: []const desugar.Annotation,

    /// The scheme a signature declared for `id`, if one was written.
    pub fn annotationOf(self: *const Program, id: core.SymbolId) ?desugar.Annotation {
        for (self.annotations) |a| {
            if (a.symbol == id) return a;
        }
        return null;
    }

    /// The definitions the entry module declared, in declaration order.
    pub fn entryDefinitions(self: *const Program) []const core.Definition {
        return self.definitions[self.entry_offset..];
    }

    pub fn deinit(self: *Program) void {
        self.datatypes.deinit();
        self.primitives.deinit();
        self.interner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

/// One `name = term` line per definition the entry module declared, in
/// declaration order. Library definitions linked in beneath it are omitted.
pub fn printProgram(
    p: *const Program,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const printer: core.Printer = .{ .interner = &p.interner };
    for (p.entryDefinitions(), 0..) |d, i| {
        if (i > 0) try w.writeByte('\n');
        try w.print("{s} = ", .{p.interner.spelling(d.symbol)});
        try printer.term(d.body, w);
    }
}

/// Desugars source files into one linked program.
///
/// Sources are added in link order: the entry source is last.
/// `finish` assembles them and hands the arena to the `Program` it returns,
/// leaving this holding nothing.
pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    arena: ?*std.heap.ArenaAllocator,
    interned: builtin.Interned,
    modules: std.ArrayList(desugar.Module) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Desugarer {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        return .{
            .allocator = allocator,
            .arena = arena,
            .interned = try builtin.Interned.init(allocator, arena.allocator()),
        };
    }

    pub fn deinit(self: *Desugarer) void {
        self.modules.deinit(self.allocator);
        const arena = self.arena orelse return;
        self.interned.deinit();
        arena.deinit();
        self.allocator.destroy(arena);
    }

    /// Registers a module's `type` declarations before any body is desugared,
    /// so a constructor reference resolves like any other global.
    fn declareTypes(self: *Desugarer, source: cst.SourceFile, sink: *diagnostic.Sink) !void {
        const arena = self.arena.?.allocator();
        const interner = &self.interned.interner;

        for (source.declarations) |*decl| {
            if (decl.* != .type_declaration) continue;
            const declared = &decl.type_declaration;

            if (self.interned.datatypes.lookup(declared.name) != null) {
                try sink.report(
                    .duplicate_definition,
                    declared.span,
                    "`{s}` is declared more than once",
                    .{declared.name},
                );
                continue;
            }

            const id = try self.interned.datatypes.declare(
                interner,
                try arena.dupe(u8, declared.name),
                @intCast(declared.parameters.len),
                &.{},
                .{ .Eq = .fields, .Serial = .fields },
            );

            const constructors = try arena.alloc(datatypes.Constructor, declared.constructors.len);
            var failed = false;
            for (declared.constructors, constructors, 0..) |written, *out, tag| {
                const symbol = interner.intern(written.name, .vanilla) catch |err| switch (err) {
                    error.Collision => {
                        try sink.report(
                            .symbol_collision,
                            written.span,
                            "`{s}` collides with an existing symbol",
                            .{written.name},
                        );
                        failed = true;
                        continue;
                    },
                    else => |e| return e,
                };

                const fields = try arena.alloc(types.Type, written.fields.len);
                for (written.fields, fields) |field, *slot| {
                    slot.* = try self.fieldType(field, declared.*, sink) orelse {
                        failed = true;
                        break;
                    };
                }

                out.* = .{ .symbol = symbol, .tag = @intCast(tag), .fields = fields };
            }
            if (failed) continue;

            self.interned.datatypes.setConstructors(interner, id, constructors);
        }
    }

    /// A constructor field's type, with the datatype's own parameters in
    /// scope as bound variables.
    fn fieldType(
        self: *Desugarer,
        written: cst.Type,
        declared: cst.TypeDeclaration,
        sink: *diagnostic.Sink,
    ) !?types.Type {
        const arena = self.arena.?.allocator();
        switch (written.kind) {
            .variable => |name| {
                for (declared.parameters, 0..) |parameter, i| {
                    if (std.mem.eql(u8, parameter, name)) return types.variable_type(@intCast(i));
                }
                try sink.report(
                    .unresolved_name,
                    written.span,
                    "`{s}` is not a parameter of `{s}`",
                    .{ name, declared.name },
                );
                return null;
            },
            .constructor => |name| {
                if (self.interned.datatypes.lookup(name)) |id| {
                    return try types.constructed(arena, id, self.interned.datatypes.get(id).name, &.{});
                }
                if (annotation.primitiveNamed(name)) |t| return t;
                try sink.report(.unresolved_name, written.span, "`{s}` is not a type", .{name});
                return null;
            },
            .application => |a| {
                const id = self.interned.datatypes.lookup(a.constructor) orelse {
                    try sink.report(
                        .unresolved_name,
                        written.span,
                        "`{s}` is not a type",
                        .{a.constructor},
                    );
                    return null;
                };
                const arguments = try arena.alloc(types.Type, a.arguments.len);
                for (a.arguments, arguments) |argument, *slot| {
                    slot.* = try self.fieldType(argument, declared, sink) orelse return null;
                }
                return try types.constructed(arena, id, self.interned.datatypes.get(id).name, arguments);
            },
            .list => |element| {
                const inner = try self.fieldType(element.*, declared, sink) orelse return null;
                return try self.interned.datatypes.list(arena, inner);
            },
            .parenthesized => |inner| return try self.fieldType(inner.*, declared, sink),
            .function => |f| {
                const from = try self.fieldType(f.from, declared, sink) orelse return null;
                const to = try self.fieldType(f.to, declared, sink) orelse return null;
                return try types.func(arena, from, to);
            },
            .filter => |f| {
                const input = try self.fieldType(f.input, declared, sink) orelse return null;
                const output = try self.fieldType(f.output, declared, sink) orelse return null;
                return try self.interned.datatypes.filter(arena, input, output);
            },
            .record => {
                try sink.report(
                    .type_mismatch,
                    written.span,
                    "a constructor field may not be a record yet",
                    .{},
                );
                return null;
            },
        }
    }

    /// Desugars one source file and adds it to the link: collect heads,
    /// resolve bodies.
    pub fn add(
        self: *Desugarer,
        source: cst.SourceFile,
        g: *const grammar.Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        const builder = core.Builder{ .allocator = self.arena.?.allocator() };
        const interner = &self.interned.interner;

        try self.declareTypes(source, sink);

        var declarations = try resolve.collect(self.allocator, interner, source, sink);
        defer declarations.deinit();

        const definitions = try builder.slice(core.Definition, declarations.items.items.len);
        const edges = try builder.slice([]const u32, declarations.items.items.len);
        @memset(edges, &.{});

        // IMPROVE: desugar the entire module at once with a single desugar pass?
        var failed = false;
        for (declarations.items.items, 0..) |d, i| {
            var lowerer = desugar.Lowerer.init(
                builder,
                interner,
                &self.interned.datatypes,
                &declarations,
                g.language,
                sink,
            );
            defer lowerer.deinit();

            const body = lowerer.parameterized(
                d.definition.parameters,
                d.definition.body,
                null,
                d.definition.span,
            ) catch |err| switch (err) {
                error.DesugarFailed => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };

            definitions[i] = .{
                .symbol = d.symbol,
                .body = body,
                .span = d.definition.span,
            };
            edges[i] = try builder.dupeSlice(u32, lowerer.references.items);
        }

        var annotations: std.ArrayList(desugar.Annotation) = .empty;
        defer annotations.deinit(self.allocator);
        for (declarations.items.items) |d| {
            const signature = d.signature orelse continue;
            const scheme = annotation.translate(
                builder.allocator,
                self.allocator,
                signature,
                &self.interned.datatypes,
                sink,
            ) catch |err| switch (err) {
                error.BadAnnotation => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };
            try annotations.append(self.allocator, .{
                .symbol = d.symbol,
                .scheme = scheme,
                .span = signature.span,
            });
        }

        if (failed or sink.hasErrors()) return error.DesugarFailed;

        try self.modules.append(self.allocator, .{
            .definitions = definitions,
            .edges = edges,
            .annotations = try builder.dupeSlice(desugar.Annotation, annotations.items),
        });
    }

    /// Assembles the added sources into a program. The last one added is the
    /// entry module and must declare `main`.
    pub fn finish(
        self: *Desugarer,
        entry_span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) Error!Program {
        std.debug.assert(self.modules.items.len > 0);

        const arena = self.arena.?;
        const scratch = arena.allocator();

        var total: usize = 0;
        for (self.modules.items) |m| total += m.definitions.len;

        const definitions = try scratch.alloc(core.Definition, total);
        const edges = try scratch.alloc([]const u32, total);

        var offset: u32 = 0;
        var entry_offset: u32 = 0;
        for (self.modules.items, 0..) |m, i| {
            if (i + 1 == self.modules.items.len) entry_offset = offset;
            offset += try place(scratch, m, definitions, edges, offset);
        }

        const main = try entrySymbol(
            definitions[entry_offset..],
            &self.interned.interner,
            entry_span,
            sink,
        );

        var annotation_count: usize = 0;
        for (self.modules.items) |m| annotation_count += m.annotations.len;
        const annotations = try scratch.alloc(desugar.Annotation, annotation_count);
        var annotation_offset: usize = 0;
        for (self.modules.items) |m| {
            for (m.annotations) |a| {
                annotations[annotation_offset] = a;
                annotation_offset += 1;
            }
        }

        var components_result = try resolve.stronglyConnectedComponents(self.allocator, edges);
        defer components_result.deinit();

        const components = try scratch.alloc([]const u32, components_result.groups.len);
        for (components_result.groups, 0..) |c, i| {
            components[i] = try scratch.dupe(u32, c);
        }

        self.arena = null;
        return .{
            .allocator = self.allocator,
            .arena = arena,
            .definitions = definitions,
            .components = components,
            .entry = main,
            .entry_offset = entry_offset,
            .interner = self.interned.interner,
            .primitives = self.interned.table,
            .datatypes = self.interned.datatypes,
            .annotations = annotations,
        };
    }
};

/// Copies one module's definitions in at `offset`, shifting its module-local
/// edges into linked indices. Returns how many it placed.
fn place(
    scratch: std.mem.Allocator,
    m: desugar.Module,
    definitions: []core.Definition,
    edges: [][]const u32,
    offset: u32,
) std.mem.Allocator.Error!u32 {
    for (m.definitions, 0..) |d, i| definitions[offset + i] = d;

    for (m.edges, 0..) |module_local, i| {
        const shifted = try scratch.alloc(u32, module_local.len);
        for (module_local, 0..) |target, j| shifted[j] = target + offset;
        edges[offset + i] = shifted;
    }

    return @intCast(m.definitions.len);
}

fn entrySymbol(
    entry_definitions: []const core.Definition,
    interner: *const core.Interner,
    entry_span: diagnostic.Span,
    sink: *diagnostic.Sink,
) Error!core.SymbolId {
    for (entry_definitions) |d| {
        if (std.mem.eql(u8, interner.spelling(d.symbol), "main")) return d.symbol;
    }

    try sink.report(.missing_main, entry_span, "no `main` definition", .{});
    return error.LinkFailed;
}
