//! Class and instance declarations.
//!
//! Each written instance method becomes an ordinary definition, annotated
//! with the class method's scheme at the instance head.
//!
//! A class is, at run time, a datatype of its dictionaries. Consider
//!
//! ```tql
//! class Eq a => Ord a where {
//!   compare :: a -> a -> Ordering;
//! };
//! ```
//!
//! Its dictionaries are built by `dict[Ord]`, with one field for the `Eq`
//! dictionary and one per method. `compare` selects its field, and
//! `super[Ord,Eq]` selects the `Eq` one. An instance is a global holding its
//! dictionary, a function of its context's dictionaries when it has a
//! context. Inference decides which dictionary each use passes. See Classes
//! in `type_check.zig`.
//!
//! A default is a global of its own. In
//!
//! ```tql
//! class Describe a where {
//!   describe :: a -> String;
//!   tags :: a -> [String];
//!   tags x = [describe x];
//! };
//! instance Describe Int where { describe n = "int"; };
//! ```
//!
//! the default is `default[Describe,tags] :: Describe a => a -> [String]`,
//! checked once at the method's own scheme. `Int`'s instance doesn't write
//! `tags`, so `tags[Int] = default[Describe,tags]`, and the `Describe Int`
//! that use wants is solved by `instance[Describe,Int]`, the dictionary
//! `tags[Int]` is a field of.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const annotation = @import("annotation.zig");
const kinds = @import("kinds.zig");
const ModuleScope = @import("scope.zig").ModuleScope;
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// A written method of an instance, or a class's default, to be desugared
/// as the definition of `symbol`.
pub const Method = struct {
    symbol: core.SymbolId,
    definition: *const cst.Definition,
};

/// Declares one module's classes and instances.
pub const Linker = struct {
    gpa: Allocator,
    env: *core.env.Env,
    scope: *const ModuleScope,
    sink: *diagnostic.Sink,
    failed: bool = false,
    /// What each class declaration of the module registered, in order. Null
    /// for a duplicate.
    declared: []?classes.ClassId = &.{},
    /// Each default of the module's classes, once declared.
    defaults: std.ArrayList(Default) = .empty,

    const Default = struct {
        symbol: core.SymbolId,
        method: core.SymbolId,
        definition: *const cst.Definition,
    };

    fn arena(self: *const Linker) Allocator {
        return self.env.allocator();
    }

    fn module(self: *const Linker) core.ModuleId {
        return self.scope.module;
    }

    /// Registers each class's name, so a signature, context, superclass or
    /// instance head may name a class declared later in the module.
    pub fn declareClasses(self: *Linker, source: cst.SourceFile) Error!void {
        var ids: std.ArrayList(?classes.ClassId) = .empty;
        for (source.declarations) |*decl| {
            if (decl.* != .class_declaration) continue;
            const declared = &decl.class_declaration;
            if (self.module() == .prim) {
                if (self.env.classes.reservation(declared.name)) |id| {
                    self.env.classes.getMut(id).span = declared.span;
                    try ids.append(self.arena(), id);
                    continue;
                }
            }
            if (self.scope.declaredType(self.module(), declared.name) != null) {
                try self.sink.report(.duplicate_definition, declared.span, "`{s}` is declared more than once", .{declared.name});
                self.failed = true;
                try ids.append(self.arena(), null);
                continue;
            }
            try ids.append(self.arena(), try self.env.classes.declare(.{
                .name = .{ .module = self.module(), .name = try self.arena().dupe(u8, declared.name) },
                .span = declared.span,
            }));
        }
        self.declared = ids.items;
    }

    /// Each class declaration of `source` with the class it registered.
    fn collectRegistered(self: *const Linker, source: cst.SourceFile, out: *std.ArrayList(Registered)) Error!void {
        var i: usize = 0;
        for (source.declarations) |*decl| {
            if (decl.* != .class_declaration) continue;
            defer i += 1;
            const id = self.declared[i] orelse continue;
            try out.append(self.gpa, .{ .id = id, .declared = &decl.class_declaration });
        }
    }

    const Registered = struct {
        id: classes.ClassId,
        declared: *const cst.ClassDeclaration,
        /// Cleared when a superclass failed to resolve or formed a cycle.
        superclasses_resolved: bool = true,
    };

    /// Resolves each class's superclasses, then interns its methods with
    /// their schemes and its dictionary's constructor and selectors. Each
    /// class's parameter kind and the method schemes that depend on it are
    /// left in `group` to solve.
    ///
    /// Preconditions:
    /// - The module's types are declared in `group`.
    pub fn declareMembers(self: *Linker, source: cst.SourceFile, group: *kinds.Group) Error!void {
        var registered: std.ArrayList(Registered) = .empty;
        defer registered.deinit(self.gpa);
        try self.collectRegistered(source, &registered);

        for (registered.items) |r| try group.declareClass(r.id);

        for (registered.items) |*r| {
            self.env.classes.getMut(r.id).superclasses = self.superclasses(r.declared) catch |err| switch (err) {
                error.BadAnnotation => blk: {
                    self.failed = true;
                    r.superclasses_resolved = false;
                    break :blk &.{};
                },
                else => |e| return e,
            };
        }

        const cyclic = try self.rejectCycles(registered.items);
        defer self.gpa.free(cyclic);
        for (registered.items, cyclic) |r, skip| {
            if (skip) continue;
            self.methods(r.id, r.declared, group) catch |err| switch (err) {
                error.BadAnnotation => self.failed = true,
                else => |e| return e,
            };
        }
        // Once the methods have kinded every class.
        for (registered.items) |r| try self.superclassKinds(r, group);
        // Once superclasses have unified every class's kind.
        for (registered.items) |r| {
            if (group.inference.resolve(group.classes.get(r.id).?) == .row) {
                try self.sink.report(
                    .invalid_class,
                    r.declared.span,
                    "`{s}`, the parameter of `{s}`, is a row; a class ranges over types",
                    .{ r.declared.parameter, r.declared.name },
                );
                self.failed = true;
            }
        }
    }

    fn superclasses(self: *Linker, declared: *const cst.ClassDeclaration) annotation.Error![]const classes.ClassId {
        const out = try self.arena().alloc(classes.ClassId, declared.superclasses.len);
        for (declared.superclasses, out) |written, *slot| {
            slot.* = try annotation.resolveClass(self.scope, written.class, written.span, self.sink);
            if (!std.mem.eql(u8, written.variableName() orelse "", declared.parameter)) {
                try self.sink.report(
                    .invalid_class,
                    written.span,
                    "`{s}` constrains something other than `{s}`, the parameter of `{s}`",
                    .{ written.class, declared.parameter, declared.name },
                );
                return error.BadAnnotation;
            }
        }
        return out;
    }

    /// Reports each superclass of `r` whose parameter's kind is not `r`'s.
    fn superclassKinds(self: *Linker, r: Registered, group: *kinds.Group) Error!void {
        if (!r.superclasses_resolved) return;
        const own = group.classes.get(r.id).?;
        for (self.env.classes.get(r.id).superclasses, r.declared.superclasses) |super, written| {
            const kind = group.classKind(super, &self.env.classes);
            if (group.inference.unify(own, kind)) continue;
            var names: types.KindNames = .{};
            try self.sink.report(
                .kind_mismatch,
                written.span,
                "`{s}` ranges over kind `{f}`, but `{s}` over kind `{f}`",
                .{
                    written.class,
                    (try group.inference.zonk(kind, null)).named(&names),
                    r.declared.name,
                    (try group.inference.zonk(own, null)).named(&names),
                },
            );
            self.failed = true;
        }
    }

    /// Reports the first-declared class of each superclass cycle and clears
    /// the superclasses of every class in it, so entailment terminates. Marks
    /// each one's superclasses unresolved.
    /// Returns which classes were reported. The caller owns the result.
    ///
    /// Preconditions:
    /// - `members` holds consecutive ids, in declaration order.
    fn rejectCycles(self: *Linker, members: []Registered) Error![]bool {
        const reported = try self.gpa.alloc(bool, members.len);
        errdefer self.gpa.free(reported);
        @memset(reported, false);
        if (members.len == 0) return reported;

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const first = @intFromEnum(members[0].id);
        const edges = try scratch.allocator().alloc([]const u32, members.len);
        for (members, edges) |r, *edge| {
            var among: std.ArrayList(u32) = .empty;
            for (self.env.classes.get(r.id).superclasses) |super| {
                const index = @intFromEnum(super) -% first;
                if (index < members.len) try among.append(scratch.allocator(), index);
            }
            edge.* = among.items;
        }

        var found = try core.components.stronglyConnectedComponents(self.gpa, edges);
        defer found.deinit();
        for (found.groups) |group| {
            if (!core.components.cyclic(group, edges)) continue;
            const reported_index = std.mem.min(u32, group);
            const r = members[reported_index];
            try self.sink.report(.invalid_class, r.declared.span, "`{s}` is its own superclass", .{r.declared.name});
            for (group) |m| {
                self.env.classes.getMut(members[m].id).superclasses = &.{};
                members[m].superclasses_resolved = false;
            }
            reported[reported_index] = true;
            self.failed = true;
        }
        return reported;
    }

    fn methods(
        self: *Linker,
        id: classes.ClassId,
        declared: *const cst.ClassDeclaration,
        group: *kinds.Group,
    ) annotation.Error!void {
        const symbols = try self.arena().alloc(core.SymbolId, declared.methods.len);
        for (declared.methods, symbols, 0..) |*signature, *symbol, index| {
            symbol.* = self.env.interner.intern(self.module(), signature.name, .{ .method = .{
                .class = id,
                .index = @intCast(index),
            } }) catch |err| switch (err) {
                error.Collision => {
                    try self.sink.report(.symbol_collision, signature.span, "`{s}` collides with an existing symbol", .{signature.name});
                    return error.BadAnnotation;
                },
                else => |e| return e,
            };
            const scheme = try annotation.translateMethod(
                self.arena(),
                self.gpa,
                signature,
                .{ .class = id, .name = declared.name, .parameter = declared.parameter },
                group,
                self.scope,
                self.sink,
            );
            try group.setScheme(symbol.*, scheme);
        }

        const class = self.env.classes.getMut(id);
        class.methods = symbols;

        var selectors: std.ArrayList(classes.Selector) = .empty;
        for (class.superclasses) |super| {
            if (self.env.classes.evidenceOf(super) != .dictionary) continue;
            const spelling = try std.fmt.allocPrint(self.arena(), "super[{s},{s}]", .{
                declared.name,
                self.env.classes.spelling(super),
            });
            try selectors.append(self.arena(), .{
                .superclass = super,
                .symbol = try self.env.interner.generate(self.module(), spelling, .selector),
            });
        }
        class.selectors = selectors.items;
        class.constructor = try self.declareDictionary(declared.name, selectors.items.len + symbols.len);

        const written = try self.arena().alloc(?*const cst.Definition, symbols.len);
        if (!try self.slotMethods(class.*, declared.defaults, .invalid_class, written)) self.failed = true;
        const defaults = try self.arena().alloc(?core.SymbolId, symbols.len);
        for (written, defaults, symbols) |definition, *default, method| {
            const d = definition orelse {
                default.* = null;
                continue;
            };
            const spelling = try std.fmt.allocPrint(self.arena(), "default[{s},{s}]", .{ declared.name, d.name });
            default.* = try self.env.interner.generate(self.module(), spelling, .vanilla);
            try self.defaults.append(self.arena(), .{ .symbol = default.*.?, .method = method, .definition = d });
        }
        class.defaults = defaults;
        class.minimal = self.minimal(declared, class.*) catch |err| switch (err) {
            error.BadAnnotation => blk: {
                self.failed = true;
                break :blk try self.required(defaults);
            },
            else => |e| return e,
        };
    }

    /// Slots each of `definitions` at the index of the method of `class` it
    /// names. Reports, under `category`, one that names no method, and one
    /// that repeats another. Returns whether every one was slotted.
    fn slotMethods(
        self: *Linker,
        class: classes.Class,
        definitions: []const cst.Definition,
        category: diagnostic.Category,
        out: []?*const cst.Definition,
    ) Error!bool {
        @memset(out, null);
        var slotted = true;
        for (definitions) |*definition| {
            const index = self.methodIndex(class, definition.name) orelse {
                try self.sink.report(category, definition.span, "`{s}` is not a method of `{s}`", .{ definition.name, class.name.name });
                slotted = false;
                continue;
            };
            if (out[index] != null) {
                try self.sink.report(.duplicate_definition, definition.span, "`{s}` is defined more than once", .{definition.name});
                slotted = false;
                continue;
            }
            out[index] = definition;
        }
        return slotted;
    }

    fn methodIndex(self: *const Linker, class: classes.Class, name: []const u8) ?u32 {
        for (class.methods, 0..) |method, i| {
            if (std.mem.eql(u8, self.env.interner.spelling(method), name)) return @intCast(i);
        }
        return null;
    }

    /// Every method without a default.
    fn required(self: *Linker, defaults: []const ?core.SymbolId) Error!classes.Minimal {
        var out: std.ArrayList(classes.Minimal) = .empty;
        for (defaults, 0..) |d, i| {
            if (d == null) try out.append(self.arena(), .{ .method = @intCast(i) });
        }
        return .{ .all = out.items };
    }

    /// The class's `minimal`, or every method without a default when it
    /// states none. Reports one that names something other than a method,
    /// or that an instance may satisfy leaving a method without a default
    /// undefined.
    fn minimal(self: *Linker, declared: *const cst.ClassDeclaration, class: classes.Class) annotation.Error!classes.Minimal {
        if (declared.minimal.len == 0) return try self.required(class.defaults);
        if (declared.minimal.len > 1) {
            try self.sink.report(.invalid_class, declared.minimal[1].span, "`{s}` states `minimal` more than once", .{declared.name});
            return error.BadAnnotation;
        }
        const written = declared.minimal[0];
        const formula = try self.translateFormula(class, written.formula);

        const defined = try self.gpa.alloc(bool, class.defaults.len);
        defer self.gpa.free(defined);
        for (class.defaults, class.methods, 0..) |d, method, i| {
            if (d != null) continue;
            @memset(defined, true);
            defined[i] = false;
            if (!formula.satisfied(defined)) continue;
            try self.sink.report(
                .invalid_class,
                written.span,
                "an instance of `{s}` satisfying `minimal` may leave `{s}` undefined, which has no default",
                .{ declared.name, self.env.interner.spelling(method) },
            );
            return error.BadAnnotation;
        }
        return formula;
    }

    fn translateFormula(self: *Linker, class: classes.Class, written: cst.Minimal.Formula) annotation.Error!classes.Minimal {
        switch (written) {
            .method => |m| {
                const index = self.methodIndex(class, m.name) orelse {
                    try self.sink.report(.invalid_class, m.span, "`{s}` is not a method of `{s}`", .{ m.name, class.name.name });
                    return error.BadAnnotation;
                };
                return .{ .method = index };
            },
            inline .all, .any => |operands, tag| {
                const out = try self.arena().alloc(classes.Minimal, operands.len);
                for (operands, out) |o, *operand| operand.* = try self.translateFormula(class, o);
                return @unionInit(classes.Minimal, @tagName(tag), out);
            },
        }
    }

    /// Annotates each default of the module's classes with its method's
    /// scheme, and appends it to `out`.
    ///
    /// Preconditions:
    /// - The module's classes' members are declared and kinded.
    pub fn defineDefaults(self: *Linker, out: *std.ArrayList(Method)) Error!void {
        for (self.defaults.items) |d| {
            try self.env.annotate(d.symbol, .{ .scheme = self.env.schemeOf(d.method).?, .span = d.definition.span });
            try out.append(self.gpa, .{ .symbol = d.symbol, .definition = d.definition });
        }
    }

    /// `dict[C]`, a datatype of `count` parameters with one constructor
    /// holding one field of each.
    fn declareDictionary(self: *Linker, name: []const u8, count: usize) Error!core.SymbolId {
        const spelling = try std.fmt.allocPrint(self.arena(), "dict[{s}]", .{name});
        const constructor = try self.env.interner.generate(self.module(), spelling, .vanilla);
        const fields = try self.arena().alloc(types.Type, count);
        for (fields, 0..) |*field, i| field.* = types.variable_type(@intCast(i));
        const id = try self.env.datatypes.declare(&self.env.interner, self.module(), spelling, types.typeKinds(count), &.{}, .data);
        self.env.datatypes.setConstructors(&self.env.interner, id, try self.arena().dupe(datatypes.Constructor, &.{
            .{ .symbol = constructor, .tag = 0, .fields = fields },
        }));
        return constructor;
    }

    /// Declares each instance, and appends its written methods to `out` and
    /// those it leaves to its class's defaults to `generated`.
    ///
    /// Preconditions:
    /// - The members of every class in scope are declared.
    pub fn declareInstances(
        self: *Linker,
        source: cst.SourceFile,
        out: *std.ArrayList(Method),
        generated: *std.ArrayList(core.Definition),
    ) Error!void {
        for (source.declarations) |*decl| {
            if (decl.* != .instance_declaration) continue;
            self.declareInstance(&decl.instance_declaration, out, generated) catch |err| switch (err) {
                error.BadAnnotation => self.failed = true,
                else => |e| return e,
            };
        }
    }

    fn declareInstance(
        self: *Linker,
        declared: *const cst.InstanceDeclaration,
        out: *std.ArrayList(Method),
        generated: *std.ArrayList(core.Definition),
    ) annotation.Error!void {
        const class_id = try annotation.resolveClass(self.scope, declared.class, declared.span, self.sink);
        const class = self.env.classes.get(class_id);
        if (self.env.classes.evidenceOf(class_id) == .builtin) {
            try self.sink.report(
                .invalid_instance,
                declared.span,
                "`{s}` is built in and takes no instances",
                .{class.name.name},
            );
            return error.BadAnnotation;
        }

        const head = try annotation.translateInstance(self.arena(), self.gpa, declared, class.parameter, self.scope, self.sink);
        const head_datatype = self.env.datatypes.get(head.head());
        const head_name = head_datatype.name;
        const head_module = head_datatype.module;
        if (self.module() != class.name.module.? and self.module() != head_module) {
            try self.sink.report(
                .orphan_instance,
                declared.span,
                "`{s} {s}` must be declared in `{s}`, which declares `{s}`, or in `{s}`, which declares `{s}`",
                .{
                    class.name.name,
                    head_name,
                    self.env.interner.moduleName(class.name.module.?),
                    class.name.name,
                    self.env.interner.moduleName(head_module),
                    head_name,
                },
            );
            return error.BadAnnotation;
        }

        const defined = try self.gpa.alloc(?*const cst.Definition, class.methods.len);
        defer self.gpa.free(defined);
        if (!try self.slotMethods(class.*, declared.methods, .invalid_instance, defined)) return error.BadAnnotation;

        const id = try self.addInstance(.{
            .class = class_id,
            .type = head.type,
            .context = head.context,
            .methods = &.{},
            .dictionary = undefined,
            .module = self.module(),
            .span = declared.span,
        });

        const written = try self.gpa.alloc(bool, class.methods.len);
        defer self.gpa.free(written);
        for (defined, written, self.env.classes.instance(id).methods, 0..) |definition, *mark, implementation, i| {
            mark.* = definition != null;
            const d = definition orelse continue;
            try self.annotateImplementation(id, i, d.span);
            try out.append(self.gpa, .{ .symbol = implementation, .definition = d });
        }
        try self.complete(id, written, generated);
    }

    /// Reports instance `id` when the methods `defined` marks do not satisfy
    /// its class's `minimal`, and otherwise defines each other method as its
    /// class's default, appending them to `out`.
    fn complete(self: *Linker, id: classes.InstanceId, defined: []const bool, out: *std.ArrayList(core.Definition)) annotation.Error!void {
        const instance = self.env.classes.instance(id);
        const class = self.env.classes.get(instance.class);
        if (!class.minimal.satisfied(defined)) {
            const missing: Missing = .{ .formula = class.minimal, .defined = defined, .interner = &self.env.interner, .methods = class.methods };
            try self.sink.report(.invalid_instance, instance.span, "`{s} {s}` does not define {f}", .{
                class.name.name,
                self.env.datatypes.get(instance.head()).name,
                missing,
            });
            return error.BadAnnotation;
        }
        const builder: core.Builder = .{ .allocator = self.arena() };
        for (class.defaults, instance.methods, defined, 0..) |default, implementation, written, i| {
            if (written) continue;
            try self.annotateImplementation(id, i, instance.span);
            try out.append(self.gpa, .{ .symbol = implementation, .body = builder.symbol(default.?, instance.span), .span = instance.span });
        }
    }

    /// Annotates instance `id`'s implementation of method `index` with the
    /// method's scheme at the instance's head.
    fn annotateImplementation(self: *Linker, id: classes.InstanceId, index: usize, span: diagnostic.Span) Error!void {
        const instance = self.env.classes.instance(id);
        const method = self.env.classes.get(instance.class).methods[index];
        try self.env.annotate(instance.methods[index], .{
            .scheme = try self.methodScheme(self.env.schemeOf(method).?, .{ .type = instance.type, .context = instance.context }),
            .span = span,
        });
    }

    /// Adds `declared`. Reports an instance already declared for its class
    /// and head.
    fn addInstance(self: *Linker, declared: classes.Instance) annotation.Error!classes.InstanceId {
        return switch (try self.env.declareInstance(declared)) {
            .added => |id| id,
            .existing => |first| {
                try self.sink.report(
                    .duplicate_instance,
                    declared.span,
                    "`{s} {s}` is already declared in `{s}`",
                    .{ self.env.classes.spelling(declared.class), self.env.datatypes.get(declared.head()).name, self.env.interner.moduleName(self.env.classes.instance(first).module) },
                );
                return error.BadAnnotation;
            },
        };
    }

    /// A derived instance whose context is being inferred.
    const Pending = struct {
        instance: classes.InstanceId,
        datatype: datatypes.TypeId,
        declared: *const cst.DataDeclaration,
        context: std.ArrayList(types.TypeClassConstraint) = .empty,
        failed: bool = false,
    };

    /// Declares the instance each class of each `deriving` clause names,
    /// infers their contexts together, and appends their methods to `out`.
    ///
    /// Preconditions:
    /// - The module's types, the members of every class in scope, and the
    ///   module's written instances are declared.
    pub fn derive(self: *Linker, source: cst.SourceFile, out: *std.ArrayList(core.Definition)) Error!void {
        var pending: std.ArrayList(Pending) = .empty;
        defer {
            for (pending.items) |*p| p.context.deinit(self.gpa);
            pending.deinit(self.gpa);
        }
        for (source.declarations) |*decl| {
            if (decl.* != .data_declaration) continue;
            const declared = &decl.data_declaration;
            if (declared.deriving.len == 0) continue;
            const id = switch (self.scope.declaredType(self.module(), declared.name) orelse continue) {
                .datatype => |id| id,
                else => continue,
            };
            // Constructors that failed to translate were never set.
            if (self.env.datatypes.get(id).constructors.len != declared.constructors.len) continue;
            for (declared.deriving, 0..) |derived, i| {
                const instance = self.declareDerived(id, declared, declared.deriving[0..i], derived) catch |err| switch (err) {
                    error.BadAnnotation => {
                        self.failed = true;
                        continue;
                    },
                    else => |e| return e,
                };
                try pending.append(self.gpa, .{ .instance = instance, .datatype = id, .declared = declared });
            }
        }

        try self.inferContexts(pending.items);
        for (pending.items) |p| {
            if (p.failed or self.env.classes.instance(p.instance).methods.len == 0) continue;
            try self.generate(p.instance, p.datatype, out);
        }
    }

    fn declareDerived(
        self: *Linker,
        id: datatypes.TypeId,
        declared: *const cst.DataDeclaration,
        earlier: []const cst.DataDeclaration.Derived,
        derived: cst.DataDeclaration.Derived,
    ) annotation.Error!classes.InstanceId {
        const class_id = try annotation.resolveClass(self.scope, derived.class, derived.span, self.sink);
        for (earlier) |e| {
            if (!std.mem.eql(u8, e.class, derived.class)) continue;
            try self.sink.report(.invalid_deriving, derived.span, "`{s}` is derived more than once", .{derived.class});
            return error.BadAnnotation;
        }
        if (std.mem.indexOfScalar(classes.ClassId, &classes.derivable, class_id) == null) {
            const shown = .{class_id} ++ classes.derivable;
            var names = try self.env.messageNames(self.gpa, &.{}, &shown);
            defer names.deinit(self.gpa);
            const registry = &self.env.classes;
            try self.sink.report(
                .invalid_deriving,
                derived.span,
                "`{f}` cannot be derived; only `{f}`, `{f}` and `{f}` can",
                .{
                    names.class(class_id, registry.spelling(class_id)),
                    names.class(.eq, registry.spelling(.eq)),
                    names.class(.ord, registry.spelling(.ord)),
                    names.class(.serial, registry.spelling(.serial)),
                },
            );
            return error.BadAnnotation;
        }
        if (declared.representation != null and self.env.classes.evidenceOf(class_id) == .dictionary) {
            try self.sink.report(
                .invalid_deriving,
                derived.span,
                "`{s}` cannot be derived for `{s}`, which the machine represents",
                .{ derived.class, declared.name },
            );
            return error.BadAnnotation;
        }
        if (declared.newtype and self.env.classes.evidenceOf(class_id) == .builtin) {
            try self.sink.report(
                .invalid_deriving,
                derived.span,
                "`{s}` cannot be derived for `{s}`, a `newtype`",
                .{ derived.class, declared.name },
            );
            return error.BadAnnotation;
        }

        return try self.addInstance(.{
            .class = class_id,
            .type = try self.env.datatypes.applied(self.arena(), id),
            .context = &.{},
            .methods = &.{},
            .dictionary = undefined,
            .module = self.module(),
            .span = derived.span,
        });
    }

    /// Appends the method of each instance tuple type `id` was declared
    /// with that has one.
    pub fn deriveTuple(self: *Linker, id: datatypes.TypeId, out: *std.ArrayList(core.Definition)) Error!void {
        for (classes.derivable) |class_id| {
            const instance = self.env.classes.instanceFor(class_id, id).?;
            if (self.env.classes.instance(instance).methods.len > 0) try self.generate(instance, id, out);
        }
    }

    /// Sets each derived instance's context to what its fields need, reduced
    /// to constraints on its type's parameters. Starts every context empty
    /// and grows them together until none grows.
    fn inferContexts(self: *Linker, pending: []Pending) Error!void {
        var leaves: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer leaves.deinit(self.gpa);
        var givens: std.ArrayList(classes.Given(void)) = .empty;
        defer givens.deinit(self.gpa);
        var changed = true;
        while (changed) {
            changed = false;
            for (pending) |*p| {
                if (p.failed) continue;
                const instance = self.env.classes.instance(p.instance);
                const grown = p.context.items.len;
                fields: for (self.env.datatypes.get(p.datatype).constructors, p.declared.constructors) |constructor, written| {
                    for (constructor.fields, written.fields) |field, written_field| {
                        leaves.clearRetainingCapacity();
                        givens.clearRetainingCapacity();
                        try classes.assume(self.gpa, p.context.items, &givens);
                        const solution = try classes.solve(self.gpa, &self.env.classes, instance.class, field, classes.Bound{}, givens.items, classes.Check{ .collect = .{ .gpa = self.gpa, .out = &leaves } });
                        if (solution == .refuted) {
                            const culprit = solution.refuted;
                            var names = try self.env.messageNames(self.gpa, &.{ instance.type, culprit }, &.{});
                            defer names.deinit(self.gpa);
                            const class = self.env.classes.spelling(instance.class);
                            try self.sink.report(.unsatisfied_constraint, written_field.span, "`{s} {f}` needs `{s} {f}`", .{
                                class,
                                instance.type.namedOperand(&names),
                                class,
                                culprit.namedOperand(&names),
                            });
                            p.failed = true;
                            self.failed = true;
                            break :fields;
                        }
                        for (leaves.items) |leaf| {
                            if (leaf.type != .variable) {
                                var names = try self.env.messageNames(self.gpa, &.{ instance.type, leaf.type }, &.{ instance.class, leaf.class });
                                defer names.deinit(self.gpa);
                                try self.sink.report(
                                    .invalid_deriving,
                                    written_field.span,
                                    "`{f} {f}` needs `{f} {f}`, but a derived instance can only require a class of a type variable",
                                    .{
                                        names.class(instance.class, self.env.classes.spelling(instance.class)),
                                        instance.type.namedOperand(&names),
                                        names.class(leaf.class, self.env.classes.spelling(leaf.class)),
                                        leaf.type.namedOperand(&names),
                                    },
                                );
                                p.failed = true;
                                self.failed = true;
                                break :fields;
                            }
                            try p.context.append(self.gpa, leaf);
                        }
                    }
                }
                if (p.context.items.len == grown) continue;
                changed = true;
                self.env.classes.instanceMut(p.instance).context = try self.requirements(p.context.items);
            }
        }

        for (pending) |*p| {
            if (p.failed) continue;
            const kept = try classes.prune(self.gpa, &self.env.classes, p.context.items, classes.Bound{});
            self.env.classes.instanceMut(p.instance).context = try self.requirements(p.context.items[0..kept]);
        }
    }

    /// `context`, each a constraint on a bound variable, as requirements.
    fn requirements(self: *Linker, context: []const types.TypeClassConstraint) Error![]const classes.Requirement {
        const out = try self.arena().alloc(classes.Requirement, context.len);
        for (context, out) |c, *slot| slot.* = .{ .class = c.class, .variable = c.type.variable };
        return out;
    }

    /// Appends the derived instance's first method, annotated with the class
    /// method's scheme at its head, and its class's defaults for the rest.
    fn generate(self: *Linker, id: classes.InstanceId, datatype: datatypes.TypeId, out: *std.ArrayList(core.Definition)) Error!void {
        const instance = self.env.classes.instance(id);
        const class = self.env.classes.get(instance.class);
        const span = instance.span;
        const derivation: Derivation = .{
            .builder = .{ .allocator = self.arena() },
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
            .class = instance.class,
            .method = class.methods[0],
            .itself = instance.methods[0],
            .datatype = datatype,
            .span = span,
        };
        try self.annotateImplementation(id, 0, span);
        try out.append(self.gpa, .{ .symbol = instance.methods[0], .body = try derivation.body(), .span = span });
        const defined = try self.gpa.alloc(bool, class.methods.len);
        defer self.gpa.free(defined);
        @memset(defined, false);
        defined[0] = true;
        self.complete(id, defined, out) catch |err| switch (err) {
            error.BadAnnotation => self.failed = true,
            else => |e| return e,
        };
    }

    /// A class method's scheme at an instance head: the head's variables
    /// come first, then the method's own, and the instance's context replaces
    /// the class's own constraint.
    fn methodScheme(self: *Linker, method: types.Scheme, head: annotation.InstanceHead) Error!types.Scheme {
        const parameters = classes.parameterCount(head.type);
        const arguments = try self.arena().alloc(types.Type, method.variables.len);
        arguments[0] = head.type;
        for (arguments[1..], 0..) |*argument, i| argument.* = types.variable_type(@intCast(parameters + i));

        const constraints = try self.arena().alloc(types.TypeClassConstraint, head.context.len + method.constraints.len - 1);
        for (head.context, constraints[0..head.context.len]) |r, *slot| slot.* = r.constraint();
        for (method.constraints[1..], constraints[head.context.len..]) |c, *slot| {
            slot.* = .{ .class = c.class, .type = try types.substitute(self.arena(), c.type, arguments) };
        }
        return .{
            .variables = try std.mem.concat(self.arena(), types.Kind, &.{
                self.env.datatypes.get(head.head()).parameters[0..parameters],
                method.variables[1..],
            }),
            .constraints = constraints,
            .type = try types.substitute(self.arena(), method.type, arguments),
        };
    }
};

/// The part of `formula` that `defined` leaves unsatisfied, as a message
/// names it: "`a` and (`b` or `c`)".
const Missing = struct {
    formula: classes.Minimal,
    defined: []const bool,
    interner: *const core.Interner,
    methods: []const core.SymbolId,

    pub fn format(self: Missing, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(self.formula, false, w);
    }

    fn write(self: Missing, formula: classes.Minimal, nested: bool, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (formula) {
            .method => |i| try w.print("`{s}`", .{self.interner.spelling(self.methods[i])}),
            inline .all, .any => |operands, tag| {
                const separator = if (tag == .all) " and " else " or ";
                var shown: usize = 0;
                for (operands) |o| shown += @intFromBool(!o.satisfied(self.defined));
                const grouped = nested and shown > 1;
                if (grouped) try w.writeByte('(');
                var first = true;
                for (operands) |o| {
                    if (o.satisfied(self.defined)) continue;
                    if (!first) try w.writeAll(separator);
                    first = false;
                    try self.write(o, nested or shown > 1, w);
                }
                if (grouped) try w.writeByte(')');
            },
        }
    }
};

/// Builds a derived `eq` or `compare`, which compares constructor tags, then
/// fields left to right through each field type's own instance.
///
/// Every field but the last is compared as a `case` scrutinee and the last in
/// tail position. A field of the type itself, at its own parameters, is
/// compared by the method being derived.
const Derivation = struct {
    builder: core.Builder,
    interner: *core.Interner,
    datatypes: *const datatypes.Registry,
    /// `.eq` or `.ord`.
    class: classes.ClassId,
    /// The class's method.
    method: core.SymbolId,
    /// The method being derived.
    itself: core.SymbolId,
    datatype: datatypes.TypeId,
    span: diagnostic.Span,

    const Alternative = core.Case.Alternative;

    /// `\x y -> case x of { C_i xs -> case y of { C_j ys -> ... } }`.
    fn body(self: Derivation) Error!core.Term {
        const b = self.builder;
        const constructors = self.datatypes.get(self.datatype).constructors;
        const x = try self.interner.fresh("x");
        const y = try self.interner.fresh("y");
        const outer = try b.slice(Alternative, constructors.len);
        for (constructors, outer, 0..) |left, *alternative, i| {
            const xs = try self.binders(left.fields.len, "a");
            const inner = try b.slice(Alternative, constructors.len);
            for (constructors, inner, 0..) |right, *matched, j| {
                const ys = try self.binders(right.fields.len, if (i == j) "b" else "_");
                matched.* = .{
                    .constructor = right.symbol,
                    .binders = ys,
                    .body = if (i == j) try self.fields(left.fields, xs, ys) else self.differ(i < j),
                };
            }
            alternative.* = .{
                .constructor = left.symbol,
                .binders = xs,
                .body = try b.case(b.symbol(y, self.span), inner, self.span),
            };
        }
        const matched = try b.case(b.symbol(x, self.span), outer, self.span);
        return try b.lambda(x, try b.lambda(y, matched, self.span), self.span);
    }

    fn binders(self: Derivation, count: usize, spelling: []const u8) Error![]core.SymbolId {
        const out = try self.builder.slice(core.SymbolId, count);
        for (out) |*binder| binder.* = try self.interner.fresh(spelling);
        return out;
    }

    /// The answer for two values built by different constructors, the first
    /// declared `earlier` than the second or not.
    fn differ(self: Derivation, earlier: bool) core.Term {
        return switch (self.class) {
            .eq => self.constant(self.datatypes.boolConstructor(false)),
            else => self.constant(self.datatypes.orderingConstructor(if (earlier) .lt else .gt)),
        };
    }

    /// The answer for two values whose fields all compare equal.
    fn same(self: Derivation) core.Term {
        return switch (self.class) {
            .eq => self.constant(self.datatypes.boolConstructor(true)),
            else => self.constant(self.datatypes.orderingConstructor(.eq)),
        };
    }

    fn constant(self: Derivation, c: datatypes.Constructor) core.Term {
        return self.builder.symbol(c.symbol, self.span);
    }

    /// Compares `xs` with `ys` pairwise, stopping at the first pair that
    /// decides.
    fn fields(self: Derivation, field_types: []const types.Type, xs: []const core.SymbolId, ys: []const core.SymbolId) Error!core.Term {
        if (field_types.len == 0) return self.same();
        const b = self.builder;
        const last = field_types.len - 1;
        var result = try self.field(field_types[last], xs[last], ys[last]);
        var i = last;
        while (i > 0) {
            i -= 1;
            const compared = try self.field(field_types[i], xs[i], ys[i]);
            result = switch (self.class) {
                .eq => try b.choose(self.datatypes, compared, self.differ(true), result, self.span),
                else => try b.chooseOrder(self.datatypes, compared, .{ self.differ(true), result, self.differ(false) }, self.span),
            };
        }
        return result;
    }

    fn field(self: Derivation, t: types.Type, x: core.SymbolId, y: core.SymbolId) Error!core.Term {
        const b = self.builder;
        const function = if (self.isItself(t)) self.itself else self.method;
        return try b.applyMany(b.symbol(function, self.span), &.{ b.symbol(x, self.span), b.symbol(y, self.span) }, self.span);
    }

    /// Whether `t` is the type being derived at its own parameters, in order.
    fn isItself(self: Derivation, t: types.Type) bool {
        if (t != .constructor or t.constructor.name != self.datatype) return false;
        for (t.constructor.arguments, 0..) |argument, i| {
            if (argument != .variable or argument.variable != i) return false;
        }
        return true;
    }
};
