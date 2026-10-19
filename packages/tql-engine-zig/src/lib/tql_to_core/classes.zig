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
const deriving = @import("../deriving.zig");
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
        for (source.declarations) |decl| switch (decl) {
            .class_declaration => |declared| try ids.append(self.arena(), try self.declareClass(declared.name, null, declared.span)),
            .primitive_class => |declared| {
                const written = declared.representation;
                const primitive = try self.libraryPrimitive(classes.Primitive, "class", written.name, written.span) orelse {
                    self.failed = true;
                    continue;
                };
                _ = try self.declareClass(declared.name, primitive, declared.span);
            },
            else => {},
        };
        self.declared = ids.items;
    }

    /// Declares the class `name`, bound to `primitive` when there is one.
    /// Reports a name declared twice.
    fn declareClass(self: *Linker, name: []const u8, primitive: ?classes.Primitive, span: diagnostic.Span) Error!?classes.ClassId {
        if (self.scope.declaredType(self.module(), name) != null) {
            try self.sink.report(.duplicate_definition, span, .{ diagnostic.code(name), " is declared more than once" });
            self.failed = true;
            return null;
        }
        return try self.env.classes.declare(.{
            .name = .{ .module = self.module(), .name = try self.arena().dupe(u8, name) },
            .primitive = primitive,
            .span = span,
        });
    }

    /// The tag of `E` that `written` names, a `what`. Reports one named
    /// outside the library and one naming no `what`.
    fn libraryPrimitive(self: *Linker, comptime E: type, comptime what: []const u8, written: []const u8, span: diagnostic.Span) Error!?E {
        if (!self.env.isLibrary(self.module())) {
            try self.sink.report(.unresolved_name, span, .{ diagnostic.code(written), " is not defined outside the library" });
            return null;
        }
        return core.primitiveNamed(E, written) orelse {
            try self.sink.report(.unresolved_name, span, .{ diagnostic.code(written), " is not a " ++ what });
            return null;
        };
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
                try self.sink.report(.invalid_class, r.declared.span, .{ diagnostic.code(r.declared.parameter), ", the parameter of ", diagnostic.code(r.declared.name), ", is a row; a class ranges over types" });
                self.failed = true;
            }
        }
    }

    fn superclasses(self: *Linker, declared: *const cst.ClassDeclaration) annotation.Error![]const classes.ClassId {
        const out = try self.arena().alloc(classes.ClassId, declared.superclasses.len);
        for (declared.superclasses, out) |written, *slot| {
            slot.* = try annotation.constraintClass(self.scope, written, self.sink);
            if (self.env.classes.get(slot.*).parameter == .row) {
                const unqualified: types.MessageNames = .{};
                try self.sink.report(.invalid_class, written.span, .{ diagnostic.code(unqualified.class(&self.env.classes, slot.*)), " ranges over rows; a class ranges over types" });
                return error.BadAnnotation;
            }
            if (!std.mem.eql(u8, written.variableName() orelse "", declared.parameter)) {
                try self.sink.report(.invalid_class, written.span, .{ diagnostic.code(written.class), " constrains something other than ", diagnostic.code(declared.parameter), ", the parameter of ", diagnostic.code(declared.name) });
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
            try self.sink.report(.kind_mismatch, written.span, .{ diagnostic.code(written.class), " ranges over kind ", diagnostic.code((try group.inference.zonk(kind, null)).named(&names)), ", but ", diagnostic.code(r.declared.name), " over kind ", diagnostic.code((try group.inference.zonk(own, null)).named(&names)) });
            self.failed = true;
        }
    }

    /// Reports the first-declared class of each superclass cycle and clears
    /// the superclasses of every class in it, so entailment terminates. Marks
    /// each one's superclasses unresolved.
    /// Returns which classes were reported. The caller owns the result.
    ///
    /// Preconditions:
    /// - `members` is in declaration order.
    fn rejectCycles(self: *Linker, members: []Registered) Error![]bool {
        const reported = try self.gpa.alloc(bool, members.len);
        errdefer self.gpa.free(reported);
        @memset(reported, false);
        if (members.len == 0) return reported;

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var index: std.AutoHashMapUnmanaged(classes.ClassId, u32) = .empty;
        for (members, 0..) |r, i| try index.put(scratch.allocator(), r.id, @intCast(i));
        const edges = try scratch.allocator().alloc([]const u32, members.len);
        for (members, edges) |r, *edge| {
            var among: std.ArrayList(u32) = .empty;
            for (self.env.classes.get(r.id).superclasses) |super| {
                if (index.get(super)) |i| try among.append(scratch.allocator(), i);
            }
            edge.* = among.items;
        }

        var found = try core.components.stronglyConnectedComponents(self.gpa, edges);
        defer found.deinit();
        for (found.groups) |group| {
            if (!core.components.cyclic(group, edges)) continue;
            const reported_index = std.mem.min(u32, group);
            const r = members[reported_index];
            try self.sink.report(.invalid_class, r.declared.span, .{ diagnostic.code(r.declared.name), " is its own superclass" });
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
                    try self.sink.report(.symbol_collision, signature.span, .{ diagnostic.code(signature.name), " collides with an existing symbol" });
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
        try self.declareAllSuperclasses(class.*);

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

    /// Gives `All C`, for `class` `C`, `All S` for each superclass `S` of
    /// `C`, selected by `map[C,S]`: `C`'s evidence record with `super[C,S]`
    /// applied to each field.
    fn declareAllSuperclasses(self: *Linker, class: classes.Class) Error!void {
        const all = self.env.classes.getMut(class.role.declared);
        const supers = try self.arena().alloc(classes.ClassId, class.selectors.len);
        const selectors = try self.arena().alloc(classes.Selector, class.selectors.len);
        for (class.selectors, supers, selectors) |selector, *super, *slot| {
            super.* = self.env.classes.get(selector.superclass).role.declared;
            const spelling = try std.fmt.allocPrint(self.arena(), "map[{s},{s}]", .{
                class.name.name,
                self.env.classes.spelling(selector.superclass),
            });
            slot.* = .{ .superclass = super.*, .symbol = try self.env.interner.generate(self.module(), spelling, .vanilla) };
        }
        all.superclasses = supers;
        all.selectors = selectors;
    }

    /// The deriver `declared` names, if it names one. Reports a second, one
    /// named outside the library, and a primitive that is not a deriver.
    fn writtenDeriver(self: *Linker, declared: *const cst.ClassDeclaration) annotation.Error!?classes.Deriver {
        if (declared.derivers.len == 0) return null;
        if (declared.derivers.len > 1) {
            try self.sink.report(.invalid_class, declared.derivers[1].span, .{ diagnostic.code(declared.name), " names its deriver more than once" });
            return error.BadAnnotation;
        }
        const written = declared.derivers[0];
        return try self.libraryPrimitive(classes.Deriver, "deriver", written.primitive, written.span) orelse error.BadAnnotation;
    }

    /// Resolves the deriver each class of the module names. Reports one that
    /// cannot derive its class, and leaves the class underivable.
    ///
    /// Preconditions:
    /// - The module's classes' members are declared and kinded.
    pub fn declareDerivers(self: *Linker, source: cst.SourceFile) Error!void {
        var registered: std.ArrayList(Registered) = .empty;
        defer registered.deinit(self.gpa);
        try self.collectRegistered(source, &registered);
        for (registered.items) |r| {
            const written = self.writtenDeriver(r.declared) catch |err| switch (err) {
                error.BadAnnotation => {
                    self.failed = true;
                    continue;
                },
                else => |e| return e,
            } orelse continue;
            const class = self.env.classes.getMut(r.id);
            switch (try deriving.resolve(self.env, class.*, written)) {
                .derived => |derived| class.deriver = derived,
                .misfit => |misfit| {
                    const span = r.declared.derivers[0].span;
                    const primitive = diagnostic.code(.{ "%", @tagName(written) });
                    const method = diagnostic.code(written.method());
                    const name = diagnostic.code(class.name.name);
                    switch (misfit) {
                        .undeclared => try self.sink.report(.invalid_class, span, .{ primitive, " defines ", method, ", which ", name, " does not declare" }),
                        .mistyped => try self.sink.report(.invalid_class, span, .{ primitive, " defines ", method, ", which ", name, " declares at another type" }),
                        .unsatisfied => try self.sink.report(.invalid_class, span, .{ primitive, " defines only ", method, ", which does not satisfy ", name, "'s ", diagnostic.code("minimal") }),
                    }
                    self.failed = true;
                },
            }
        }
        for (registered.items) |r| try self.declareRecord(r.id);
    }

    /// Gives class `id` its `record[C]` when its deriver ranges over a whole
    /// type and each of its superclasses has one.
    fn declareRecord(self: *Linker, id: classes.ClassId) Error!void {
        const class = self.env.classes.get(id);
        if (class.record != null or self.env.classes.wholeTypeDeriver(id) == null) return;
        for (class.superclasses) |super| {
            try self.declareRecord(super);
            if (self.env.classes.get(super).record == null) return;
        }
        const spelling = try std.fmt.allocPrint(self.arena(), "record[{s}]", .{class.name.name});
        self.env.classes.getMut(id).record = try self.env.interner.generate(self.module(), spelling, .vanilla);
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
            const index = class.methodNamed(&self.env.interner, definition.name) orelse {
                try self.sink.report(category, definition.span, .{ diagnostic.code(definition.name), " is not a method of ", diagnostic.code(class.name.name) });
                slotted = false;
                continue;
            };
            if (out[index] != null) {
                try self.sink.report(.duplicate_definition, definition.span, .{ diagnostic.code(definition.name), " is defined more than once" });
                slotted = false;
                continue;
            }
            out[index] = definition;
        }
        return slotted;
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
            try self.sink.report(.invalid_class, declared.minimal[1].span, .{ diagnostic.code(declared.name), " states ", diagnostic.code("minimal"), " more than once" });
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
            try self.sink.report(.invalid_class, written.span, .{ "an instance of ", diagnostic.code(declared.name), " satisfying ", diagnostic.code("minimal"), " may leave ", diagnostic.code(self.env.interner.spelling(method)), " undefined, which has no default" });
            return error.BadAnnotation;
        }
        return formula;
    }

    fn translateFormula(self: *Linker, class: classes.Class, written: cst.Minimal.Formula) annotation.Error!classes.Minimal {
        switch (written) {
            .method => |m| {
                const index = class.methodNamed(&self.env.interner, m.name) orelse {
                    try self.sink.report(.invalid_class, m.span, .{ diagnostic.code(m.name), " is not a method of ", diagnostic.code(class.name.name) });
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
        const head = try annotation.translateInstance(self.arena(), self.gpa, declared, class.parameter, self.scope, self.sink);
        const head_datatype = self.env.datatypes.get(head.head());
        const head_name = head_datatype.name;
        const head_module = head_datatype.module;
        if (self.module() != class.name.module.? and self.module() != head_module) {
            try self.sink.report(.orphan_instance, declared.span, .{ diagnostic.code(.{ class.name.name, " ", head_name }), " must be declared in ", diagnostic.code(self.env.interner.moduleName(class.name.module.?)), ", which declares ", diagnostic.code(class.name.name), ", or in ", diagnostic.code(self.env.interner.moduleName(head_module)), ", which declares ", diagnostic.code(head_name) });
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
            var message: diagnostic.Message = .init(self.sink.allocator);
            defer message.deinit();
            try message.append(.{ diagnostic.code(.{ class.name.name, " ", self.env.datatypes.get(instance.head()).name }), " does not define " });
            try missing.append(&message);
            try self.sink.add(.invalid_instance, instance.span, &message);
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
                try self.sink.report(.duplicate_instance, declared.span, .{ diagnostic.code(.{ self.env.classes.spelling(declared.class), " ", self.env.datatypes.get(declared.head()).name }), " is already declared in ", diagnostic.code(self.env.interner.moduleName(self.env.classes.instance(first).module)) });
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
            if (p.failed) continue;
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
            try self.sink.report(.invalid_deriving, derived.span, .{ diagnostic.code(derived.class), " is derived more than once" });
            return error.BadAnnotation;
        }
        const class = self.env.classes.get(class_id);
        const resolved = class.deriver orelse {
            var names = try self.env.messageNames(self.gpa, &.{}, &.{class_id});
            defer names.deinit(self.gpa);
            try self.sink.report(.invalid_deriving, derived.span, .{ diagnostic.code(names.class(&self.env.classes, class_id)), " cannot be derived; its class names no deriver" });
            return error.BadAnnotation;
        };
        if (declared.representation != null) {
            try self.sink.report(.invalid_deriving, derived.span, .{ diagnostic.code(derived.class), " cannot be derived for ", diagnostic.code(declared.name), ", which the machine represents" });
            return error.BadAnnotation;
        }
        const parameters = self.env.datatypes.get(id).parameters;
        if (resolved.deriver.overLast() and parameters.len == 0) {
            try self.sink.report(.invalid_deriving, derived.span, .{ diagnostic.code(derived.class), " ranges over ", diagnostic.code(declared.name), "'s last parameter, which it does not have" });
            return error.BadAnnotation;
        }
        const applied = if (resolved.deriver.overLast()) parameters.len - 1 else parameters.len;
        const kind = try types.Kind.arrows(self.arena(), parameters[applied..], .type);
        if (!class.parameter.eql(kind)) {
            var names: types.KindNames = .{};
            try self.sink.report(.invalid_deriving, derived.span, .{ diagnostic.code(derived.class), " ranges over kind ", diagnostic.code(class.parameter.named(&names)), ", but ", diagnostic.code(declared.name), if (resolved.deriver.overLast()) " without its last parameter" else "", " has kind ", diagnostic.code(kind.named(&names)) });
            return error.BadAnnotation;
        }
        return try self.addInstance(.{
            .class = class_id,
            .type = try self.env.datatypes.appliedTo(self.arena(), id, applied),
            .context = &.{},
            .methods = &.{},
            .dictionary = undefined,
            .module = self.module(),
            .span = derived.span,
        });
    }

    /// Appends the methods of each instance `Env.declareTupleInstances`
    /// declared tuple type `id` with.
    pub fn deriveTuple(self: *Linker, id: datatypes.TypeId, out: *std.ArrayList(core.Definition)) Error!void {
        for (0..self.env.classes.classes.items.len) |i| {
            const class: classes.ClassId = @enumFromInt(i);
            if (self.env.classes.wholeTypeDeriver(class) == null) continue;
            try self.generate(self.env.classes.instanceFor(class, id).?, id, out);
        }
    }

    /// Sets each derived instance's context to what its fields want, reduced
    /// to constraints on its type's parameters. Starts every context empty
    /// and grows them together until none grows.
    fn inferContexts(self: *Linker, pending: []Pending) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (pending) |*p| {
                if (p.failed) continue;
                const grown = p.context.items.len;
                fields: for (self.env.datatypes.get(p.datatype).constructors, p.declared.constructors) |constructor, written| {
                    for (constructor.fields, written.fields) |field, written_field| {
                        try self.inferField(p, field, written_field.span);
                        if (!p.failed) continue;
                        self.failed = true;
                        break :fields;
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

    /// Grows `p`'s context by what a field of type `field` wants. Reports a
    /// wanted no context can solve, and marks `p` failed.
    fn inferField(self: *Linker, p: *Pending, field: types.Type, span: diagnostic.Span) Error!void {
        var wanted: std.ArrayList(types.Type) = .empty;
        defer wanted.deinit(self.gpa);
        var leaves: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer leaves.deinit(self.gpa);
        var givens: std.ArrayList(classes.Given(void)) = .empty;
        defer givens.deinit(self.gpa);
        const instance = self.env.classes.instance(p.instance);
        const class = self.env.classes.spelling(instance.class);
        const deriver = self.env.classes.get(instance.class).deriver.?.deriver;
        const last: types.TypeVar = @intCast(self.env.datatypes.get(p.datatype).parameters.len -| 1);
        if (try deriving.wanteds(self.gpa, self.env, deriver, field, last, &wanted)) |unreachable_at| {
            var names = try self.env.messageNames(self.gpa, &.{unreachable_at}, &.{});
            defer names.deinit(self.gpa);
            try self.sink.report(.invalid_deriving, span, .{ diagnostic.code(class), " cannot be derived through ", diagnostic.code(unreachable_at.named(&names)) });
            p.failed = true;
            return;
        }
        for (wanted.items) |w| {
            leaves.clearRetainingCapacity();
            givens.clearRetainingCapacity();
            try classes.assume(self.gpa, p.context.items, &givens);
            const solution = try classes.solve(self.gpa, &self.env.classes, instance.class, w, classes.Bound{}, givens.items, classes.Check{ .collect = .{ .gpa = self.gpa, .out = &leaves } });
            if (solution == .refuted) {
                const culprit = solution.refuted;
                var names = try self.env.messageNames(self.gpa, &.{ instance.type, culprit }, &.{});
                defer names.deinit(self.gpa);
                try self.sink.report(.unsatisfied_constraint, span, .{ diagnostic.code(.{ class, " ", instance.type.namedOperand(&names) }), " needs ", diagnostic.code(.{ class, " ", culprit.namedOperand(&names) }) });
                p.failed = true;
                return;
            }
            for (leaves.items) |leaf| {
                if (leaf.type != .variable) {
                    var names = try self.env.messageNames(self.gpa, &.{ instance.type, leaf.type }, &.{ instance.class, leaf.class });
                    defer names.deinit(self.gpa);
                    try self.sink.report(.invalid_deriving, span, .{ diagnostic.code(.{ names.class(&self.env.classes, instance.class), " ", instance.type.namedOperand(&names) }), " needs ", diagnostic.code(.{ names.class(&self.env.classes, leaf.class), " ", leaf.type.namedOperand(&names) }), ", but a derived instance can only require a class of a type variable" });
                    p.failed = true;
                    return;
                }
                try p.context.append(self.gpa, leaf);
            }
        }
    }

    /// `context`, each a constraint on a bound variable, as requirements.
    fn requirements(self: *Linker, context: []const types.TypeClassConstraint) Error![]const classes.Requirement {
        const out = try self.arena().alloc(classes.Requirement, context.len);
        for (context, out) |c, *slot| slot.* = .{ .class = c.class, .variable = c.type.variable };
        return out;
    }

    /// Appends the method the derived instance's deriver defines, annotated
    /// with the class method's scheme at its head, and its class's defaults
    /// for the rest.
    fn generate(self: *Linker, id: classes.InstanceId, datatype: datatypes.TypeId, out: *std.ArrayList(core.Definition)) Error!void {
        const instance = self.env.classes.instance(id);
        const class = self.env.classes.get(instance.class);
        const derived = class.deriver.?;
        const span = instance.span;
        const derivation: deriving.Derivation = .{
            .builder = .{ .allocator = self.arena() },
            .env = self.env,
            .derived = derived,
            .method = class.methods[derived.method],
            .itself = instance.methods[derived.method],
            .datatype = datatype,
            .span = span,
        };
        try self.annotateImplementation(id, derived.method, span);
        try out.append(self.gpa, .{ .symbol = instance.methods[derived.method], .body = try derivation.body(), .span = span });
        const defined = try self.gpa.alloc(bool, class.methods.len);
        defer self.gpa.free(defined);
        @memset(defined, false);
        defined[derived.method] = true;
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

    fn append(self: Missing, message: *diagnostic.Message) Error!void {
        try self.write(self.formula, false, message);
    }

    fn write(self: Missing, formula: classes.Minimal, nested: bool, message: *diagnostic.Message) Error!void {
        switch (formula) {
            .method => |i| try message.append(.{diagnostic.code(self.interner.spelling(self.methods[i]))}),
            inline .all, .any => |operands, tag| {
                const separator = if (tag == .all) " and " else " or ";
                var shown: usize = 0;
                for (operands) |o| shown += @intFromBool(!o.satisfied(self.defined));
                const grouped = nested and shown > 1;
                if (grouped) try message.append(.{"("});
                var first = true;
                for (operands) |o| {
                    if (o.satisfied(self.defined)) continue;
                    if (!first) try message.append(.{separator});
                    first = false;
                    try self.write(o, nested or shown > 1, message);
                }
                if (grouped) try message.append(.{")"});
            },
        }
    }
};
