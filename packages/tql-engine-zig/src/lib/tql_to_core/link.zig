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
const kinds = @import("kinds.zig");
const classes_mod = @import("classes.zig");
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
    /// Every definition added so far, in link order.
    definitions: std.ArrayList(core.Definition) = .empty,
    /// `edges[i]` holds the linked indices `definitions[i]` references.
    edges: std.ArrayList([]const u32) = .empty,
    /// Where the last source added begins in `definitions`.
    entry_offset: u32 = 0,
    /// The linked index of every definition added so far.
    linked: std.AutoHashMapUnmanaged(core.SymbolId, u32) = .empty,
    /// What each module added so far exports, by `ModuleId`.
    exports: std.ArrayList(scope_mod.Exports) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Desugarer {
        var target = try core.env.Env.init(allocator);
        errdefer target.deinit();
        try primitives.populate(&target);
        return .{ .allocator = allocator, .env = target };
    }

    /// A desugarer holding everything `base` has added. It shares what `base`
    /// allocated, so `base` must outlive it and every program it finishes,
    /// and must not change meanwhile.
    pub fn extend(allocator: std.mem.Allocator, base: *const Desugarer) !Desugarer {
        var target = try base.env.?.clone(allocator);
        errdefer target.deinit();
        var definitions = try base.definitions.clone(allocator);
        errdefer definitions.deinit(allocator);
        var edges = try base.edges.clone(allocator);
        errdefer edges.deinit(allocator);
        var linked = try base.linked.clone(allocator);
        errdefer linked.deinit(allocator);
        return .{
            .allocator = allocator,
            .env = target,
            .definitions = definitions,
            .edges = edges,
            .entry_offset = base.entry_offset,
            .linked = linked,
            .exports = try base.exports.clone(allocator),
        };
    }

    pub fn deinit(self: *Desugarer) void {
        self.definitions.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.linked.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        if (self.env) |*target| target.deinit();
    }

    /// Registers a module's `data` and `type` declarations before any body is
    /// desugared, so a constructor reference resolves like any other global.
    ///
    /// An alias body or constructor field may name a type declared below it.
    /// Their kinds, and the constructors that depend on them, are left in
    /// `group` to solve.
    fn declareTypes(
        self: *Desugarer,
        scope: *const ModuleScope,
        source: cst.SourceFile,
        group: *kinds.Group,
        sink: *diagnostic.Sink,
    ) !void {
        const arena = self.env.?.allocator();
        const interner = &self.env.?.interner;
        const registry = &self.env.?.datatypes;

        const Pending = struct { declared: *const cst.DataDeclaration, id: datatypes.TypeId };
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(self.allocator);

        for (source.declarations) |*decl| {
            if (decl.* != .data_declaration) continue;
            const declared = &decl.data_declaration;
            const taken = scope.declaredType(scope.module, declared.name);
            const existing = if (taken) |t| switch (t) {
                .datatype => |id| id,
                else => null,
            } else null;
            // A structural type is reserved before any source is read, so
            // `Prim`'s declaration fills in the row already standing rather
            // than opening a new one.
            const reserved = if (existing) |id| self.env.?.datatypes.get(id).reserved else false;

            if (taken != null and !reserved) {
                try sink.report(
                    .duplicate_definition,
                    declared.span,
                    "`{s}` is declared more than once",
                    .{declared.name},
                );
                continue;
            }
            if (reserved) {
                const s = datatypes.Registry.structuralNamed(declared.name).?;
                if (!conforms(s, declared.*)) {
                    try self.reportNonconforming(s, declared.*, sink);
                    continue;
                }
                self.env.?.datatypes.claim(existing.?);
            } else if (declared.representation) |r| {
                try sink.report(
                    .type_mismatch,
                    r.span,
                    "`{s}` is not a built-in type, so it cannot be represented as `{s}`",
                    .{ declared.name, r.name },
                );
                continue;
            }

            const id = existing orelse blk: {
                // Kinded once the module's declarations are solved.
                const id = try registry.declare(interner, scope.module, try arena.dupe(u8, declared.name), &.{}, &.{}, if (declared.newtype) .newtype else .data);
                try group.declare(id, declared.parameters.len);
                break :blk id;
            };
            try pending.append(self.allocator, .{ .declared = declared, .id = id });
        }

        try self.declareAliases(scope, source, group, sink);

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
                    slot.* = annotation.translateField(arena, self.allocator, field, declared, p.id, group, scope, sink) catch |err| switch (err) {
                        error.BadAnnotation => {
                            failed = true;
                            break;
                        },
                        else => |e| return e,
                    };
                }

                out.* = .{ .symbol = symbol, .tag = @intCast(tag), .fields = fields };
            }
            if (!failed) try group.setConstructors(p.id, constructors);
        }
    }

    /// Translates a module's aliases into `group`, each after the aliases
    /// its body names.
    fn declareAliases(
        self: *Desugarer,
        scope: *const ModuleScope,
        source: cst.SourceFile,
        group: *kinds.Group,
        sink: *diagnostic.Sink,
    ) !void {
        var aliases: std.ArrayList(*const cst.TypeAlias) = .empty;
        defer aliases.deinit(self.allocator);

        for (source.declarations) |*decl| {
            if (decl.* != .type_alias) continue;
            const alias = &decl.type_alias;
            const repeated = for (aliases.items) |earlier| {
                if (std.mem.eql(u8, earlier.name, alias.name)) break true;
            } else false;
            if (repeated or scope.declaredType(scope.module, alias.name) != null) {
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
        for (0..aliases.items.len) |i| _ = try self.declareAlias(scope, aliases.items, states, i, group, sink);
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
        group: *kinds.Group,
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
            if (!try self.declareAlias(scope, aliases, states, j, group, sink)) {
                states[i] = .failed;
                return false;
            }
        }

        const translated = annotation.translateAlias(
            self.env.?.allocator(),
            self.allocator,
            aliases[i],
            group,
            scope,
            sink,
        ) catch |err| switch (err) {
            error.BadAnnotation => {
                states[i] = .failed;
                return false;
            },
            else => |e| return e,
        };
        try group.define(translated);
        states[i] = .declared;
        return true;
    }

    /// Whether a written declaration matches what the evaluator expects of a
    /// structural type: the same arity, the same representation, and the
    /// same constructor spellings in the same tag order.
    fn conforms(s: datatypes.Registry.Structural, declared: cst.DataDeclaration) bool {
        if (declared.parameters.len != s.parameters.len) return false;
        const representation: ?types.Primitive = if (declared.representation) |r|
            std.meta.stringToEnum(types.Primitive, r.name[1..]) orelse return false
        else
            null;
        if (!std.meta.eql(representation, s.representation)) return false;
        if (declared.constructors.len != s.constructors.len) return false;
        for (declared.constructors, s.constructors) |written, expected| {
            if (!std.mem.eql(u8, written.name, expected)) return false;
        }
        return true;
    }

    fn reportNonconforming(self: *Desugarer, s: datatypes.Registry.Structural, declared: cst.DataDeclaration, sink: *diagnostic.Sink) !void {
        if (s.representation) |p| {
            try sink.report(
                .type_mismatch,
                declared.span,
                "`{s}` is represented by the machine and must be declared as `data {s} = %{s};`",
                .{ declared.name, p.spelling(), p.spelling() },
            );
            return;
        }
        const spelled = try std.mem.join(self.allocator, "`, `", s.constructors);
        defer self.allocator.free(spelled);
        try sink.report(
            .type_mismatch,
            declared.span,
            "`{s}` is built directly by the evaluator and must declare {d} " ++
                "parameter(s) and the constructors `{s}` in that order",
            .{ declared.name, s.parameters.len, spelled },
        );
    }

    /// Declares a module for `add`. The library's modules are declared
    /// already.
    pub fn declareModule(self: *Desugarer, name: []const u8) !core.ModuleId {
        return try self.env.?.interner.declareModule(name);
    }

    /// Desugars one source file as `module` and adds it to the link: declare
    /// classes, types and instances, collect heads, resolve bodies. Kinds and
    /// fields resolve against grammar `g`.
    ///
    /// Preconditions:
    /// - Each module `imports` names was added before.
    /// - Every module declared before `module` was added.
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
        const tuples_before = self.env.?.tuples;
        const scope: ModuleScope = .{
            .module = module,
            .imports = imports,
            .exports = self.exports.items,
            .env = &self.env.?,
        };

        // The module's datatypes, aliases and classes are kinded together:
        // each parameter's kind is what their bodies, fields and methods need
        // of it, or `Type` where they leave it open.
        var group = kinds.Group.init(self.env.?.allocator(), self.allocator);
        defer group.deinit();
        var class_linker: classes_mod.Linker = .{ .gpa = self.allocator, .env = &self.env.?, .scope = &scope, .sink = sink };
        try class_linker.declareClasses(source);
        try self.declareTypes(&scope, source, &group, sink);
        try class_linker.declareMembers(source, &group);
        try group.commit(&self.env.?, module);
        var methods: std.ArrayList(classes_mod.Method) = .empty;
        defer methods.deinit(self.allocator);
        try class_linker.declareInstances(source, &methods);
        var generated: std.ArrayList(core.Definition) = .empty;
        defer generated.deinit(self.allocator);
        try class_linker.derive(source, &generated);

        var declarations = try resolve.collect(self.allocator, interner, module, source, sink);
        defer declarations.deinit();
        for (methods.items) |m| try declarations.items.append(self.allocator, .{
            .name = m.definition.name,
            .symbol = m.symbol,
            .kind = .{ .value = .{ .definition = m.definition } },
        });

        if (!try scope.checkImports(sink)) return error.DesugarFailed;
        const header_exports: cst.Filter = if (source.header) |h| h.exports else .all;
        const exports = try scope.exportsOf(self.env.?.allocator(), header_exports, sink) orelse
            return error.DesugarFailed;
        var failed = class_linker.failed;

        const first: u32 = @intCast(self.linked.count());
        for (declarations.items.items, first..) |d, index| {
            try self.linked.put(self.allocator, d.symbol, @intCast(index));
        }

        const written = declarations.items.items.len;
        const definitions = try builder.slice(core.Definition, written);
        const edges = try builder.slice([]const u32, written);
        @memset(edges, &.{});

        const language = if (g) |known| known.language else null;
        var lowerer = desugar.Lowerer.init(builder, &self.env.?, &scope, language, sink);
        for (declarations.items.items, 0..) |d, i| {
            const lowered = switch (d.kind) {
                .value => |v| lowerer.parameterized(v.definition.parameters, v.definition.body, null, v.definition.span),
                .synonym => |s| match.matcherOf(&lowerer, s.declaration),
            };
            const body = lowered catch |err| switch (err) {
                error.DesugarFailed => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };

            definitions[i] = .{ .symbol = d.symbol, .body = body, .span = d.span() };
            edges[i] = try self.references(builder, body);
            if (d.kind == .synonym) try self.env.?.markAlwaysInline(d.symbol);
        }
        if (!try checkSynonymCycles(self.allocator, declarations.items.items, edges[0..written], first, sink)) {
            failed = true;
        }

        for (declarations.items.items) |d| {
            const span, const translated = switch (d.kind) {
                .value => |v| blk: {
                    const signature = v.signature orelse continue;
                    break :blk .{ signature.span, annotation.translate(builder.allocator, self.allocator, signature, &scope, sink) };
                },
                .synonym => |s| blk: {
                    const signature = s.signature orelse continue;
                    const arity: u32 = @intCast(s.declaration.parameters.len);
                    break :blk .{ signature.span, annotation.translateSynonym(builder.allocator, self.allocator, signature, arity, &scope, sink) };
                },
            };
            const scheme = translated catch |err| switch (err) {
                error.BadAnnotation => {
                    failed = true;
                    continue;
                },
                else => |e| return e,
            };
            try self.env.?.annotate(d.symbol, .{ .scheme = scheme, .span = span });
        }

        for (self.env.?.tuples, tuples_before) |now, before| {
            if (before == null) if (now) |id| try class_linker.deriveTuple(id, &generated);
        }
        if (failed or sink.hasErrors()) return error.DesugarFailed;

        self.entry_offset = first;
        try self.definitions.appendSlice(self.allocator, definitions);
        try self.edges.appendSlice(self.allocator, edges);
        for (generated.items) |method| {
            try self.linked.put(self.allocator, method.symbol, @intCast(self.definitions.items.len));
            try self.definitions.append(self.allocator, method);
            try self.edges.append(self.allocator, try self.references(builder, method.body));
        }
        std.debug.assert(self.exports.items.len == @intFromEnum(module));
        try self.exports.append(self.allocator, exports);
    }

    /// The linked indices of the definitions `body` mentions, in first-mention
    /// order.
    fn references(self: *const Desugarer, builder: core.Builder, body: core.Term) ![]const u32 {
        var collector: core.free.Collector = .{ .gpa = self.allocator, .locals = .{ .keys = &self.linked } };
        defer collector.deinit();
        try collector.walk(body);

        const targets = try builder.slice(u32, collector.out.items.len);
        for (collector.out.items, targets) |symbol, *target| target.* = self.linked.get(symbol).?;
        return targets;
    }

    /// Assembles the added sources into a program. The last one added is the
    /// entry module and must declare `main`.
    pub fn finish(
        self: *Desugarer,
        entry_span: diagnostic.Span,
        sink: *diagnostic.Sink,
    ) Error!Program {
        const scratch = self.env.?.allocator();

        if (!try classes_mod.checkSuperclasses(self.allocator, &self.env.?, sink)) return error.LinkFailed;

        const definitions = try scratch.dupe(core.Definition, self.definitions.items);
        const edges = self.edges.items;
        const entry_offset = self.entry_offset;

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
            .entry_end = @intCast(definitions.len),
        };
    }
};

/// Reports each synonym whose matcher calls itself, directly or through the
/// matchers of other synonyms of `declarations`. Returns whether there was
/// none.
///
/// Preconditions:
/// - `references[i]` holds the linked indices the definition of
///   `declarations[i]` references.
/// - `declarations` are linked in order from `first`.
fn checkSynonymCycles(
    gpa: std.mem.Allocator,
    declarations: []const resolve.Declaration,
    references: []const []const u32,
    first: u32,
    sink: *diagnostic.Sink,
) !bool {
    for (declarations) |d| {
        if (d.kind == .synonym) break;
    } else return true;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const edges = try allocator.alloc([]const u32, declarations.len);
    for (declarations, references, edges) |d, targets, *edge| {
        var among: std.ArrayList(u32) = .empty;
        if (d.kind == .synonym) for (targets) |target| {
            if (target < first or target - first >= declarations.len) continue;
            const index = target - first;
            if (declarations[index].kind == .synonym) try among.append(allocator, index);
        };
        edge.* = among.items;
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
                try others.writer.print(", through `{s}`", .{declarations[other].name});
            }
            try sink.report(
                .cyclic_synonym,
                declarations[member].span(),
                "`{s}` is defined in terms of itself{s}",
                .{ declarations[member].name, others.written() },
            );
        }
    }
    return ok;
}

/// Appends every type name `t` mentions to `out`.
fn typeNames(gpa: std.mem.Allocator, t: cst.Type, out: *std.ArrayList([]const u8)) !void {
    switch (t.kind) {
        .constructor => |name| try out.append(gpa, name),
        .application => |a| {
            switch (a.head) {
                .constructor => |name| try out.append(gpa, name),
                .variable, .tuple => {},
            }
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
        .tuple => |components| for (components) |component| try typeNames(gpa, component, out),
        .tuple_constructor => {},
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
