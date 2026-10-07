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
const match = @import("match.zig");
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
    /// What each module exports, by `ModuleId`.
    exports: std.ArrayList(cst.Filter) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Desugarer {
        var target = try core.env.Env.init(allocator);
        errdefer target.deinit();
        try primitives.populate(&target);

        var exports: std.ArrayList(cst.Filter) = .empty;
        try exports.append(allocator, .all);
        return .{ .allocator = allocator, .env = target, .exports = exports };
    }

    pub fn deinit(self: *Desugarer) void {
        self.modules.deinit(self.allocator);
        self.linked.deinit(self.allocator);
        self.exports.deinit(self.allocator);
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

            if ((existing != null and structural == null) or
                self.env.?.datatypes.aliasNamed(scope.module, declared.name) != null or
                self.env.?.datatypes.primitiveNamed(scope.module, declared.name) != null)
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
                    slot.* = annotation.translateField(arena, self.allocator, field, declared, scope, sink) catch |err| switch (err) {
                        error.BadAnnotation => {
                            failed = true;
                            break;
                        },
                        else => |e| return e,
                    };
                }

                out.* = .{ .symbol = symbol, .tag = @intCast(tag), .fields = fields };
            }
            if (failed) continue;

            try self.env.?.setConstructors(p.id, constructors);
        }
    }

    /// Translates a module's aliases, each after the aliases its body names.
    fn declareAliases(self: *Desugarer, scope: *const ModuleScope, source: cst.SourceFile, sink: *diagnostic.Sink) !void {
        var aliases: std.ArrayList(*const cst.TypeAlias) = .empty;
        defer aliases.deinit(self.allocator);

        for (source.declarations) |*decl| {
            if (decl.* != .type_alias) continue;
            const alias = &decl.type_alias;
            const repeated = for (aliases.items) |earlier| {
                if (std.mem.eql(u8, earlier.name, alias.name)) break true;
            } else false;
            if (repeated or self.env.?.datatypes.lookup(scope.module, alias.name) != null or
                self.env.?.datatypes.aliasNamed(scope.module, alias.name) != null or
                self.env.?.datatypes.primitiveNamed(scope.module, alias.name) != null)
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

    /// Declares a module for `add`. `ModuleId.prelude` is declared already.
    pub fn declareModule(self: *Desugarer, name: []const u8, exports: cst.Filter) !core.ModuleId {
        try self.exports.append(self.allocator, exports);
        return try self.env.?.interner.declareModule(name);
    }

    /// Desugars one source file as `module` and adds it to the link: collect
    /// heads, resolve bodies. Kinds and fields resolve against grammar `g`.
    ///
    /// Preconditions:
    /// - Each module `imports` names was added before.
    pub fn add(
        self: *Desugarer,
        module: core.ModuleId,
        imports: []const scope_mod.Import,
        source: cst.SourceFile,
        g: ?*const grammar.Grammar,
        sink: *diagnostic.Sink,
    ) !void {
        const builder = core.Builder{ .allocator = self.env.?.allocator() };
        const interner = &self.env.?.interner;
        const scope: ModuleScope = .{
            .module = module,
            .imports = imports,
            .exports = self.exports.items,
            .interner = interner,
            .datatypes = &self.env.?.datatypes,
        };

        try self.declareTypes(&scope, source, sink);

        var declarations = try resolve.collect(self.allocator, interner, module, source, sink);
        defer declarations.deinit();

        if (!try scope.checkItems(sink)) return error.DesugarFailed;
        var failed = !try checkSynonymCycles(self.allocator, &scope, declarations.synonyms.items, sink);

        // A synonym's matcher is a definition, linked after the module's own.
        const written = declarations.items.items.len;
        const offset: u32 = @intCast(self.linked.count());
        for (declarations.items.items, 0..) |d, i| {
            const index: u32 = @intCast(i);
            try self.linked.put(self.allocator, d.symbol, offset + index);
        }
        for (declarations.synonyms.items, written..) |s, i| {
            const index: u32 = @intCast(i);
            try self.linked.put(self.allocator, s.symbol, offset + index);
        }

        const definitions = try builder.slice(core.Definition, written + declarations.synonyms.items.len);
        const edges = try builder.slice([]const u32, definitions.len);
        @memset(edges, &.{});

        // IMPROVE: desugar the entire module at once with a single desugar pass?
        for (declarations.items.items, 0..) |d, i| {
            var lowerer = desugar.Lowerer.init(
                builder,
                &self.env.?,
                &scope,
                &self.linked,
                if (g) |known| known.language else null,
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

        if (!failed) for (declarations.synonyms.items, written..) |s, i| {
            var lowerer = desugar.Lowerer.init(
                builder,
                &self.env.?,
                &scope,
                &self.linked,
                if (g) |known| known.language else null,
                sink,
            );
            defer lowerer.deinit();

            const body = match.matcherOf(&lowerer, s.declaration) catch |err| switch (err) {
                error.DesugarFailed => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };

            definitions[i] = .{
                .symbol = s.symbol,
                .body = body,
                .span = s.declaration.span,
            };
            edges[i] = try builder.dupeSlice(u32, lowerer.references.items);
            try self.env.?.markAlwaysInline(s.symbol);
        };

        for (declarations.synonyms.items) |s| {
            const signature = s.signature orelse continue;
            const scheme = annotation.translateSynonym(
                builder.allocator,
                self.allocator,
                signature,
                @intCast(s.declaration.parameters.len),
                &scope,
                sink,
            ) catch |err| switch (err) {
                error.BadAnnotation => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };
            try self.env.?.annotate(s.symbol, .{
                .scheme = scheme,
                .span = signature.span,
            });
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
            try self.env.?.annotate(d.symbol, .{
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

        // A reference to a signed definition is not a dependency.
        for (edges) |*edge| {
            var kept: std.ArrayList(u32) = .empty;
            for (edge.*) |target| {
                if (self.env.?.annotationOf(definitions[target].symbol) == null) {
                    try kept.append(scratch, target);
                }
            }
            edge.* = kept.items;
        }

        var components_result = try core.components.stronglyConnectedComponents(self.allocator, edges);
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

/// Reports each synonym whose body uses itself, directly or through other
/// synonyms of `synonyms`. Returns whether there was none.
fn checkSynonymCycles(
    gpa: std.mem.Allocator,
    scope: *const ModuleScope,
    synonyms: []const resolve.Synonym,
    sink: *diagnostic.Sink,
) !bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const edges = try allocator.alloc([]const u32, synonyms.len);
    for (synonyms, edges) |s, *edge| {
        var used: std.ArrayList(u32) = .empty;
        try synonymsUsed(allocator, scope, synonyms, s.declaration.body, &used);
        edge.* = used.items;
    }

    var found = try core.components.stronglyConnectedComponents(gpa, edges);
    defer found.deinit();

    var ok = true;
    for (found.groups) |members| {
        if (!core.components.cyclic(members, edges)) continue;
        ok = false;
        for (members) |member| {
            var others: std.Io.Writer.Allocating = .init(allocator);
            for (members) |other| {
                if (other == member) continue;
                try others.writer.print(", through `{s}`", .{synonyms[other].name});
            }
            try sink.report(
                .cyclic_synonym,
                synonyms[member].declaration.span,
                "`{s}` is defined in terms of itself{s}",
                .{ synonyms[member].name, others.written() },
            );
        }
    }
    return ok;
}

/// Appends the index in `synonyms` of each one `pattern` uses.
fn synonymsUsed(
    allocator: std.mem.Allocator,
    scope: *const ModuleScope,
    synonyms: []const resolve.Synonym,
    pattern: cst.Pattern,
    out: *std.ArrayList(u32),
) !void {
    switch (pattern.kind) {
        .variable, .literal, .boolean => {},
        .constructor, .synonym => |c| {
            if (c.builtin == null) {
                if (scope.value(c.name) == .found) {
                    const symbol = scope.value(c.name).found;
                    for (synonyms, 0..) |s, i| {
                        if (s.symbol == symbol) try out.append(allocator, @intCast(i));
                    }
                }
            }
            for (c.arguments) |argument| try synonymsUsed(allocator, scope, synonyms, argument, out);
        },
        .list => |elements| for (elements) |element| try synonymsUsed(allocator, scope, synonyms, element, out),
        .cons => |c| {
            try synonymsUsed(allocator, scope, synonyms, c.head, out);
            try synonymsUsed(allocator, scope, synonyms, c.tail, out);
        },
        .as => |a| try synonymsUsed(allocator, scope, synonyms, a.pattern, out),
        .conjunction => |c| {
            try synonymsUsed(allocator, scope, synonyms, c.left, out);
            try synonymsUsed(allocator, scope, synonyms, c.right, out);
        },
        .view => |v| try synonymsUsed(allocator, scope, synonyms, v.pattern, out),
        .node => |n| for (n.fields) |f| try synonymsUsed(allocator, scope, synonyms, f.pattern, out),
    }
}

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
