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
const primitives = @import("../primitives.zig");
const datatypes = core.datatypes;
const types = core.types;

pub const Error = error{LinkFailed} || std.mem.Allocator.Error;

const Program = core.Program;

/// Desugars source files into one linked program.
///
/// Sources are added in link order: the entry source is last.
/// `finish` assembles them and hands the arena to the `Program` it returns,
/// leaving this holding nothing.
pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    /// Null once `finish` has handed it to the `Program`.
    env: ?core.env.Env,
    modules: std.ArrayList(desugar.Module) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Desugarer {
        var target = try core.env.Env.init(allocator);
        errdefer target.deinit();
        try primitives.populate(&target);

        return .{ .allocator = allocator, .env = target };
    }

    pub fn deinit(self: *Desugarer) void {
        self.modules.deinit(self.allocator);
        if (self.env) |*target| target.deinit();
    }

    /// Registers a module's `type` declarations before any body is desugared,
    /// so a constructor reference resolves like any other global.
    fn declareTypes(self: *Desugarer, source: cst.SourceFile, sink: *diagnostic.Sink) !void {
        const arena = self.env.?.allocator();
        const interner = &self.env.?.interner;

        for (source.declarations) |*decl| {
            if (decl.* != .type_declaration) continue;
            const declared = &decl.type_declaration;

            // A structural type is reserved before any source is read, so its
            // declaration fills in the row already standing rather than
            // opening a new one.
            const structural = datatypes.Registry.structuralNamed(declared.name);
            const existing = self.env.?.datatypes.lookup(declared.name);

            // A declared type is found before a primitive one, so this would
            // silently replace `Int` in every signature.
            if (annotation.primitiveNamed(declared.name) != null) {
                try sink.report(
                    .symbol_collision,
                    declared.span,
                    "`{s}` is a built-in type",
                    .{declared.name},
                );
                continue;
            }

            if (existing != null and structural == null) {
                try sink.report(
                    .duplicate_definition,
                    declared.span,
                    "`{s}` is declared more than once",
                    .{declared.name},
                );
                continue;
            }
            if (structural) |s| {
                if (self.env.?.datatypes.get(existing.?).constructors.len > 0) {
                    try sink.report(
                        .duplicate_definition,
                        declared.span,
                        "`{s}` is declared more than once",
                        .{declared.name},
                    );
                    continue;
                }
                if (!conforms(s, declared.*)) {
                    const spelled = try std.mem.join(self.allocator, "`, `", s.constructors);
                    defer self.allocator.free(spelled);
                    try sink.report(
                        .type_mismatch,
                        declared.span,
                        "`{s}` is built directly by the evaluator and must declare {d} " ++
                            "parameter(s) and the constructors `{s}` in that order",
                        .{ declared.name, s.parameters, spelled },
                    );
                    continue;
                }
            }

            const id = existing orelse try self.env.?.datatypes.declare(
                interner,
                try arena.dupe(u8, declared.name),
                @intCast(declared.parameters.len),
                &.{},
                .{ .Eq = .fields },
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

            self.env.?.datatypes.setConstructors(interner, id, constructors);
        }
    }

    /// Whether a written declaration matches what the evaluator expects of a
    /// structural type: the same arity, and the same constructor spellings in
    /// the same tag order.
    fn conforms(s: datatypes.Registry.Structural, declared: cst.TypeDeclaration) bool {
        if (declared.parameters.len != s.parameters) return false;
        if (declared.constructors.len != s.constructors.len) return false;
        for (declared.constructors, s.constructors) |written, expected| {
            if (!std.mem.eql(u8, written.name, expected)) return false;
        }
        return true;
    }

    /// A constructor field's type, with the datatype's own parameters in
    /// scope as bound variables.
    fn fieldType(
        self: *Desugarer,
        written: cst.Type,
        declared: cst.TypeDeclaration,
        sink: *diagnostic.Sink,
    ) !?types.Type {
        const arena = self.env.?.allocator();
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
                if (self.env.?.datatypes.lookup(name)) |id| {
                    const parameters = self.env.?.datatypes.get(id).parameters;
                    if (parameters != 0) {
                        try sink.report(
                            .type_mismatch,
                            written.span,
                            "`{s}` takes {d} type argument(s), given 0",
                            .{ name, parameters },
                        );
                        return null;
                    }
                    return try types.constructed(arena, id, self.env.?.datatypes.get(id).name, &.{});
                }
                if (annotation.primitiveNamed(name)) |t| return t;
                try sink.report(.unresolved_name, written.span, "`{s}` is not a type", .{name});
                return null;
            },
            .application => |a| {
                const id = self.env.?.datatypes.lookup(a.constructor) orelse {
                    try sink.report(
                        .unresolved_name,
                        written.span,
                        "`{s}` is not a type",
                        .{a.constructor},
                    );
                    return null;
                };
                const parameters = self.env.?.datatypes.get(id).parameters;
                if (a.arguments.len != parameters) {
                    try sink.report(
                        .type_mismatch,
                        written.span,
                        "`{s}` takes {d} type argument(s), given {d}",
                        .{ a.constructor, parameters, a.arguments.len },
                    );
                    return null;
                }
                const arguments = try arena.alloc(types.Type, a.arguments.len);
                for (a.arguments, arguments) |argument, *slot| {
                    slot.* = try self.fieldType(argument, declared, sink) orelse return null;
                }
                return try types.constructed(arena, id, self.env.?.datatypes.get(id).name, arguments);
            },
            .list => |element| {
                const inner = try self.fieldType(element.*, declared, sink) orelse return null;
                return try self.env.?.datatypes.list(arena, inner);
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
                return try self.env.?.datatypes.filter(arena, input, output);
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
        const builder = core.Builder{ .allocator = self.env.?.allocator() };
        const interner = &self.env.?.interner;

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
                &self.env.?.datatypes,
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

        for (declarations.items.items) |d| {
            const signature = d.signature orelse continue;
            const scheme = annotation.translate(
                builder.allocator,
                self.allocator,
                signature,
                &self.env.?.datatypes,
                sink,
            ) catch |err| switch (err) {
                error.BadAnnotation => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };
            try self.env.?.annotate(.{
                .symbol = d.symbol,
                .scheme = scheme,
                .span = signature.span,
            });
        }

        if (failed or sink.hasErrors()) return error.DesugarFailed;

        try self.modules.append(self.allocator, .{
            .definitions = definitions,
            .edges = edges,
        });
    }

    /// Assembles the added sources into a program. The last one added is the
    /// entry module and must declare `main`.
    pub fn finish(
        self: *Desugarer,
        entry_span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) Error!Program {
        const scratch = self.env.?.allocator();

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
            &self.env.?.interner,
            entry_span,
            sink,
        );

        var components_result = try resolve.stronglyConnectedComponents(self.allocator, edges);
        defer components_result.deinit();

        const components = try scratch.alloc([]const u32, components_result.groups.len);
        for (components_result.groups, 0..) |c, i| {
            components[i] = try scratch.dupe(u32, c);
        }

        const target = self.env.?;
        self.env = null;
        return .{
            .env = target,
            .definitions = definitions,
            .components = components,
            .entry = main,
            .entry_offset = entry_offset,
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
