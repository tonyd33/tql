//! Assembles desugared Core modules into a `Program`.
//!
//! Modules link in order, the entry module last. Definitions are concatenated
//! and Tarjan runs once over the merged graph, whose edges are linked indices
//! and cross module boundaries. Per-module SCCs would hold only while no cycle
//! crosses a module boundary and modules arrive in dependency order; one
//! whole-program pass does not depend on either.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const grammar = @import("../lang/grammar.zig");
const annotation = @import("annotation.zig");
const resolve = @import("resolve.zig");
const scope_mod = @import("scope.zig");
const desugar = @import("desugar.zig");
const primitives = @import("../primitives.zig");
const datatypes = core.datatypes;
const types = core.types;

pub const Error = error{LinkFailed} || std.mem.Allocator.Error;

const Program = core.Program;
const ModuleScope = scope_mod.ModuleScope;

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
    /// The linked index of every definition added so far.
    linked: std.AutoHashMapUnmanaged(core.SymbolId, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Desugarer {
        var target = try core.env.Env.init(allocator);
        errdefer target.deinit();
        try primitives.populate(&target);

        return .{ .allocator = allocator, .env = target };
    }

    pub fn deinit(self: *Desugarer) void {
        self.modules.deinit(self.allocator);
        self.linked.deinit(self.allocator);
        if (self.env) |*target| target.deinit();
    }

    /// Registers a module's `data` and `type` declarations before any body is
    /// desugared, so a constructor reference resolves like any other global.
    ///
    /// An alias body or constructor field may name a type declared below it.
    fn declareTypes(self: *Desugarer, scope: *const ModuleScope, source: cst.SourceFile, sink: *diagnostic.Sink) !void {
        const arena = self.env.?.allocator();
        const interner = &self.env.?.interner;

        const Pending = struct { declared: *const cst.DataDeclaration, id: datatypes.TypeId };
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(self.allocator);

        for (source.declarations) |*decl| {
            if (decl.* != .data_declaration) continue;
            const declared = &decl.data_declaration;

            // A structural type is reserved before any source is read, so the
            // prelude's declaration fills in the row already standing rather
            // than opening a new one.
            const structural = if (scope.module == .prelude)
                datatypes.Registry.structuralNamed(declared.name)
            else
                null;
            const existing = self.env.?.datatypes.lookup(scope.module, declared.name);

            // A declared type is found before a primitive one, so this would
            // silently replace `Int` in every signature.
            if (annotation.builtinNamed(declared.name) != null) {
                try sink.report(
                    .symbol_collision,
                    declared.span,
                    "`{s}` is a built-in type",
                    .{declared.name},
                );
                continue;
            }

            if ((existing != null and structural == null) or
                self.env.?.datatypes.aliasNamed(scope.module, declared.name) != null)
            {
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
                scope.module,
                try arena.dupe(u8, declared.name),
                @intCast(declared.parameters.len),
                &.{},
                .{ .Eq = .fields },
            );
            try pending.append(self.allocator, .{ .declared = declared, .id = id });
        }

        try self.declareAliases(scope, source, sink);

        for (pending.items) |p| {
            const declared = p.declared;
            const constructors = try arena.alloc(datatypes.Constructor, declared.constructors.len);
            var failed = false;
            for (declared.constructors, constructors, 0..) |written, *out, tag| {
                const symbol = interner.intern(scope.module, written.name, .vanilla) catch |err| switch (err) {
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
                    slot.* = try self.fieldType(scope, field, declared.*, sink) orelse {
                        failed = true;
                        break;
                    };
                }

                out.* = .{ .symbol = symbol, .tag = @intCast(tag), .fields = fields };
            }
            if (failed) continue;

            self.env.?.datatypes.setConstructors(interner, p.id, constructors);
        }
    }

    /// Translates a module's aliases, each after the aliases its body names.
    fn declareAliases(self: *Desugarer, scope: *const ModuleScope, source: cst.SourceFile, sink: *diagnostic.Sink) !void {
        var aliases: std.ArrayList(*const cst.TypeAlias) = .empty;
        defer aliases.deinit(self.allocator);

        for (source.declarations) |*decl| {
            if (decl.* != .type_alias) continue;
            const alias = &decl.type_alias;
            if (annotation.builtinNamed(alias.name) != null) {
                try sink.report(.symbol_collision, alias.span, "`{s}` is a built-in type", .{alias.name});
                continue;
            }
            const repeated = for (aliases.items) |earlier| {
                if (std.mem.eql(u8, earlier.name, alias.name)) break true;
            } else false;
            if (repeated or self.env.?.datatypes.lookup(scope.module, alias.name) != null or
                self.env.?.datatypes.aliasNamed(scope.module, alias.name) != null)
            {
                try sink.report(
                    .duplicate_definition,
                    alias.span,
                    "`{s}` is declared more than once",
                    .{alias.name},
                );
                continue;
            }
            try aliases.append(self.allocator, alias);
        }

        const states = try self.allocator.alloc(AliasState, aliases.items.len);
        defer self.allocator.free(states);
        @memset(states, .unvisited);
        for (0..aliases.items.len) |i| _ = try self.declareAlias(scope, aliases.items, states, i, sink);
    }

    const AliasState = enum { unvisited, visiting, declared, failed };

    /// Declares `aliases[i]` after every alias of `aliases` its body names.
    /// Returns whether it was declared.
    fn declareAlias(
        self: *Desugarer,
        scope: *const ModuleScope,
        aliases: []const *const cst.TypeAlias,
        states: []AliasState,
        i: usize,
        sink: *diagnostic.Sink,
    ) !bool {
        switch (states[i]) {
            .declared => return true,
            .failed => return false,
            .visiting => {
                try sink.report(
                    .cyclic_alias,
                    aliases[i].span,
                    "`{s}` is defined in terms of itself",
                    .{aliases[i].name},
                );
                states[i] = .failed;
                return false;
            },
            .unvisited => {},
        }
        states[i] = .visiting;

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        try typeNames(self.allocator, aliases[i].type, &names);
        for (names.items) |name| {
            const j = for (aliases, 0..) |other, j| {
                if (std.mem.eql(u8, other.name, name)) break j;
            } else continue;
            if (!try self.declareAlias(scope, aliases, states, j, sink)) {
                states[i] = .failed;
                return false;
            }
        }

        const translated = annotation.translateAlias(
            self.env.?.allocator(),
            self.allocator,
            aliases[i],
            scope,
            sink,
        ) catch |err| switch (err) {
            error.BadAnnotation => {
                states[i] = .failed;
                return false;
            },
            else => |e| return e,
        };
        try self.env.?.datatypes.defineAlias(scope.module, translated);
        states[i] = .declared;
        return true;
    }

    /// Whether a written declaration matches what the evaluator expects of a
    /// structural type: the same arity, and the same constructor spellings in
    /// the same tag order.
    fn conforms(s: datatypes.Registry.Structural, declared: cst.DataDeclaration) bool {
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
        scope: *const ModuleScope,
        written: cst.Type,
        declared: cst.DataDeclaration,
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
                switch (scope.typeNamed(name)) {
                    .found => |found| switch (found) {
                        .datatype => |id| {
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
                        },
                        .alias => |alias| return try self.aliasField(scope, alias, &.{}, written.span, declared, sink),
                    },
                    .ambiguous => |modules| {
                        try scope.reportAmbiguous(sink, written.span, name, modules);
                        return null;
                    },
                    .missing => {},
                }
                if (annotation.builtinNamed(name)) |t| {
                    if (hasRecord(t)) return try recordField(written.span, sink);
                    return t;
                }
                try sink.report(.unresolved_name, written.span, "`{s}` is not a type", .{name});
                return null;
            },
            .application => |a| {
                const id = switch (scope.typeNamed(a.constructor)) {
                    .found => |found| switch (found) {
                        .datatype => |id| id,
                        .alias => |alias| return try self.aliasField(scope, alias, a.arguments, written.span, declared, sink),
                    },
                    .ambiguous => |modules| {
                        try scope.reportAmbiguous(sink, written.span, a.constructor, modules);
                        return null;
                    },
                    .missing => {
                        try sink.report(
                            .unresolved_name,
                            written.span,
                            "`{s}` is not a type",
                            .{a.constructor},
                        );
                        return null;
                    },
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
                    slot.* = try self.fieldType(scope, argument, declared, sink) orelse return null;
                }
                return try types.constructed(arena, id, self.env.?.datatypes.get(id).name, arguments);
            },
            .list => |element| {
                const inner = try self.fieldType(scope, element.*, declared, sink) orelse return null;
                return try self.env.?.datatypes.list(arena, inner);
            },
            .parenthesized => |inner| return try self.fieldType(scope, inner.*, declared, sink),
            .function => |f| {
                const from = try self.fieldType(scope, f.from, declared, sink) orelse return null;
                const to = try self.fieldType(scope, f.to, declared, sink) orelse return null;
                return try types.func(arena, from, to);
            },
            .filter => |f| {
                const input = try self.fieldType(scope, f.input, declared, sink) orelse return null;
                const output = try self.fieldType(scope, f.output, declared, sink) orelse return null;
                return try self.env.?.datatypes.filter(arena, input, output);
            },
            .record => return try recordField(written.span, sink),
        }
    }

    /// A constructor field written as `alias` at `written`, expanded.
    fn aliasField(
        self: *Desugarer,
        scope: *const ModuleScope,
        alias: *const datatypes.Alias,
        written: []const cst.Type,
        span: diagnostic.Span,
        declared: cst.DataDeclaration,
        sink: *diagnostic.Sink,
    ) std.mem.Allocator.Error!?types.Type {
        const arena = self.env.?.allocator();
        if (written.len != alias.parameters.len) {
            try sink.report(
                .type_mismatch,
                span,
                "`{s}` takes {d} type argument(s), given {d}",
                .{ alias.name, alias.parameters.len, written.len },
            );
            return null;
        }
        const arguments = try arena.alloc(types.Type, written.len);
        for (written, arguments) |argument, *slot| {
            slot.* = try self.fieldType(scope, argument, declared, sink) orelse return null;
        }
        const applied = try alias.apply(arena, arguments);
        if (hasRecord(applied)) return try recordField(span, sink);
        return applied;
    }

    fn recordField(span: diagnostic.Span, sink: *diagnostic.Sink) !?types.Type {
        try sink.report(.type_mismatch, span, "a constructor field may not be a record yet", .{});
        return null;
    }

    /// Declares a module for `add`. `ModuleId.prelude` is declared already.
    pub fn declareModule(self: *Desugarer, name: []const u8) !core.ModuleId {
        return try self.env.?.interner.declareModule(name);
    }

    /// Desugars one source file as `module` and adds it to the link: collect
    /// heads, resolve bodies. Every declaration of each of `imports` is in
    /// scope unqualified.
    ///
    /// Preconditions:
    /// - Each of `imports` was added before.
    pub fn add(
        self: *Desugarer,
        module: core.ModuleId,
        imports: []const core.ModuleId,
        source: cst.SourceFile,
        g: *const grammar.Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        const builder = core.Builder{ .allocator = self.env.?.allocator() };
        const interner = &self.env.?.interner;
        const scope: ModuleScope = .{
            .module = module,
            .imports = imports,
            .interner = interner,
            .datatypes = &self.env.?.datatypes,
        };

        try self.declareTypes(&scope, source, sink);

        var declarations = try resolve.collect(self.allocator, interner, module, source, sink);
        defer declarations.deinit();

        const offset: u32 = @intCast(self.linked.count());
        for (declarations.items.items, 0..) |d, i| {
            const index: u32 = @intCast(i);
            try self.linked.put(self.allocator, d.symbol, offset + index);
        }

        const definitions = try builder.slice(core.Definition, declarations.items.items.len);
        const edges = try builder.slice([]const u32, declarations.items.items.len);
        @memset(edges, &.{});

        // IMPROVE: desugar the entire module at once with a single desugar pass?
        var failed = false;
        for (declarations.items.items, 0..) |d, i| {
            var lowerer = desugar.Lowerer.init(
                builder,
                interner,
                &scope,
                &self.linked,
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
                &scope,
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
            @memcpy(definitions[offset..][0..m.definitions.len], m.definitions);
            @memcpy(edges[offset..][0..m.edges.len], m.edges);
            offset += @intCast(m.definitions.len);
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

/// Appends every type name `t` mentions to `out`.
fn typeNames(gpa: std.mem.Allocator, t: cst.Type, out: *std.ArrayList([]const u8)) !void {
    switch (t.kind) {
        .constructor => |name| try out.append(gpa, name),
        .application => |a| {
            try out.append(gpa, a.constructor);
            for (a.arguments) |argument| try typeNames(gpa, argument, out);
        },
        .variable => {},
        .function => |f| {
            try typeNames(gpa, f.from, out);
            try typeNames(gpa, f.to, out);
        },
        .filter => |f| {
            try typeNames(gpa, f.input, out);
            try typeNames(gpa, f.output, out);
        },
        .list, .parenthesized => |inner| try typeNames(gpa, inner.*, out),
        .record => |r| for (r.fields) |f| try typeNames(gpa, f.type, out),
    }
}

/// Whether a record appears anywhere in `t`.
fn hasRecord(t: types.Type) bool {
    return switch (t) {
        .variable, .meta, .primitive => false,
        .record => true,
        .constructor => |c| for (c.arguments) |argument| {
            if (hasRecord(argument)) break true;
        } else false,
        .function => |arrow| hasRecord(arrow.from) or hasRecord(arrow.to),
        .alias => |a| hasRecord(a.expansion),
    };
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
