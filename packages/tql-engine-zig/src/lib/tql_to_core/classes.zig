//! Class and instance declarations.
//!
//! Each written instance method becomes an ordinary definition, annotated
//! with the class method's scheme at the instance head.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const annotation = @import("annotation.zig");
const ModuleScope = @import("scope.zig").ModuleScope;
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// A written instance method, to be desugared as the definition of `symbol`.
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

    const Registered = struct { id: classes.ClassId, declared: *const cst.ClassDeclaration };

    /// Resolves each class's superclasses, then interns its methods with
    /// their schemes and its dictionary's constructor and selectors.
    ///
    /// Preconditions:
    /// - The module's types are declared.
    pub fn declareMembers(self: *Linker, source: cst.SourceFile) Error!void {
        var registered: std.ArrayList(Registered) = .empty;
        defer registered.deinit(self.gpa);
        try self.collectRegistered(source, &registered);

        for (registered.items) |r| {
            self.env.classes.getMut(r.id).superclasses = self.superclasses(r.declared) catch |err| switch (err) {
                error.BadAnnotation => blk: {
                    self.failed = true;
                    break :blk &.{};
                },
                else => |e| return e,
            };
        }

        const cyclic = try self.rejectCycles(registered.items);
        defer self.gpa.free(cyclic);
        for (registered.items, cyclic) |r, skip| {
            if (skip) continue;
            self.methods(r.id, r.declared) catch |err| switch (err) {
                error.BadAnnotation => self.failed = true,
                else => |e| return e,
            };
        }
    }

    fn superclasses(self: *Linker, declared: *const cst.ClassDeclaration) annotation.Error![]const classes.ClassId {
        const out = try self.arena().alloc(classes.ClassId, declared.superclasses.len);
        for (declared.superclasses, out) |written, *slot| {
            slot.* = try annotation.resolveClass(self.scope, written.class, written.span, self.sink);
            if (!std.mem.eql(u8, written.variable, declared.parameter)) {
                try self.sink.report(
                    .invalid_class,
                    written.span,
                    "`{s}` is not `{s}`, the parameter of `{s}`",
                    .{ written.variable, declared.parameter, declared.name },
                );
                return error.BadAnnotation;
            }
        }
        return out;
    }

    /// Reports the first-declared class of each superclass cycle and clears
    /// the superclasses of every class in it, so entailment terminates.
    /// Returns which classes were reported. The caller owns the result.
    ///
    /// Preconditions:
    /// - `members` holds consecutive ids, in declaration order.
    fn rejectCycles(self: *Linker, members: []const Registered) Error![]bool {
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
            for (group) |m| self.env.classes.getMut(members[m].id).superclasses = &.{};
            reported[reported_index] = true;
            self.failed = true;
        }
        return reported;
    }

    fn methods(self: *Linker, id: classes.ClassId, declared: *const cst.ClassDeclaration) annotation.Error!void {
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
                .{ .class = id, .name = declared.name, .parameter = declared.parameter, .kind = self.env.classes.get(id).parameter },
                self.scope,
                self.sink,
            );
            try self.env.setScheme(symbol.*, scheme);
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
    }

    /// `dict[C]`, a datatype of `count` parameters with one constructor
    /// holding one field of each.
    fn declareDictionary(self: *Linker, name: []const u8, count: usize) Error!core.SymbolId {
        const spelling = try std.fmt.allocPrint(self.arena(), "dict[{s}]", .{name});
        const constructor = try self.env.interner.generate(self.module(), spelling, .vanilla);
        const fields = try self.arena().alloc(types.Type, count);
        for (fields, 0..) |*field, i| field.* = types.variable_type(@intCast(i));
        const id = try self.env.datatypes.declare(&self.env.interner, self.module(), spelling, types.typeKinds(count), &.{});
        self.env.datatypes.setConstructors(&self.env.interner, id, try self.arena().dupe(datatypes.Constructor, &.{
            .{ .symbol = constructor, .tag = 0, .fields = fields },
        }));
        return constructor;
    }

    /// Declares each instance, and appends its written methods to `out`.
    ///
    /// Preconditions:
    /// - The members of every class in scope are declared.
    pub fn declareInstances(self: *Linker, source: cst.SourceFile, out: *std.ArrayList(Method)) Error!void {
        for (source.declarations) |*decl| {
            if (decl.* != .instance_declaration) continue;
            self.declareInstance(&decl.instance_declaration, out) catch |err| switch (err) {
                error.BadAnnotation => self.failed = true,
                else => |e| return e,
            };
        }
    }

    fn declareInstance(self: *Linker, declared: *const cst.InstanceDeclaration, out: *std.ArrayList(Method)) annotation.Error!void {
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
        @memset(defined, null);
        for (declared.methods) |*definition| {
            const index = for (class.methods, 0..) |method, i| {
                if (std.mem.eql(u8, self.env.interner.spelling(method), definition.name)) break i;
            } else {
                try self.sink.report(
                    .invalid_instance,
                    definition.span,
                    "`{s}` is not a method of `{s}`",
                    .{ definition.name, class.name.name },
                );
                return error.BadAnnotation;
            };
            if (defined[index] != null) {
                try self.sink.report(.duplicate_definition, definition.span, "`{s}` is defined more than once", .{definition.name});
                return error.BadAnnotation;
            }
            defined[index] = definition;
        }
        for (class.methods, defined) |method, definition| {
            if (definition != null) continue;
            try self.sink.report(
                .invalid_instance,
                declared.span,
                "`{s} {s}` does not define `{s}`",
                .{ class.name.name, head_name, self.env.interner.spelling(method) },
            );
            return error.BadAnnotation;
        }

        const id = try self.addInstance(.{
            .class = class_id,
            .type = head.type,
            .context = head.context,
            .methods = &.{},
            .dictionary = undefined,
            .module = self.module(),
            .span = declared.span,
        });

        const implementations = try self.arena().alloc(core.SymbolId, class.methods.len);
        for (class.methods, defined, implementations) |method, definition, *implementation| {
            implementation.* = try self.methodSymbol(definition.?.name, head_name);
            try self.env.annotate(implementation.*, .{
                .scheme = try self.methodScheme(self.env.schemeOf(method).?, head),
                .span = definition.?.span,
            });
            try out.append(self.gpa, .{ .symbol = implementation.*, .definition = definition.? });
        }
        self.env.classes.instanceMut(id).methods = implementations;
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

    /// `method[head]`, an instance's implementation of `method`.
    fn methodSymbol(self: *Linker, method: []const u8, head: []const u8) Error!core.SymbolId {
        return try self.env.interner.generate(
            self.module(),
            try std.fmt.allocPrint(self.arena(), "{s}[{s}]", .{ method, head }),
            .instance_method,
        );
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
            try out.append(self.gpa, try self.generate(p));
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
        switch (class_id) {
            .eq, .ord, .serial => {},
            else => {
                try self.sink.report(
                    .invalid_deriving,
                    derived.span,
                    "`{s}` cannot be derived; only `Eq`, `Ord` and `Serial` can",
                    .{derived.class},
                );
                return error.BadAnnotation;
            },
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

        const class = self.env.classes.get(class_id);
        const name = self.env.datatypes.get(id).name;
        const implementations = try self.arena().alloc(core.SymbolId, class.methods.len);
        for (class.methods, implementations) |method, *implementation| {
            implementation.* = try self.methodSymbol(self.env.interner.spelling(method), name);
        }
        return try self.addInstance(.{
            .class = class_id,
            .type = try self.env.datatypes.applied(self.arena(), id),
            .context = &.{},
            .methods = implementations,
            .dictionary = undefined,
            .module = self.module(),
            .span = derived.span,
        });
    }

    /// Sets each derived instance's context to what its fields need, reduced
    /// to constraints on its type's parameters. Starts every context empty
    /// and grows them together until none grows.
    fn inferContexts(self: *Linker, pending: []Pending) Error!void {
        var leaves: std.ArrayList(types.TypeClassConstraint) = .empty;
        defer leaves.deinit(self.gpa);
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
                        const view = Bound{};
                        if (try classes.reduce(&self.env.classes, instance.class, field, view, Leaves{ .gpa = self.gpa, .out = &leaves })) |culprit| {
                            try self.sink.report(.unsatisfied_constraint, written_field.span, "`{s} {f}` needs `{s} {f}`", .{
                                self.env.classes.spelling(instance.class),
                                instance.type.operand(),
                                self.env.classes.spelling(instance.class),
                                culprit.operand(),
                            });
                            p.failed = true;
                            self.failed = true;
                            break :fields;
                        }
                        for (leaves.items) |leaf| {
                            if (self.env.classes.entailedBy(p.context.items, leaf)) continue;
                            try p.context.append(self.gpa, leaf);
                        }
                    }
                }
                if (p.context.items.len == grown) continue;
                changed = true;
                self.env.classes.instanceMut(p.instance).context = try self.arena().dupe(types.TypeClassConstraint, p.context.items);
            }
        }

        for (pending) |*p| {
            if (p.failed) continue;
            const kept = self.env.classes.pruneEntailed(p.context.items);
            self.env.classes.instanceMut(p.instance).context = try self.arena().dupe(types.TypeClassConstraint, p.context.items[0..kept]);
        }
    }

    /// The derived instance's method, annotated with the class method's
    /// scheme at its head.
    fn generate(self: *Linker, p: Pending) Error!core.Definition {
        const instance = self.env.classes.instance(p.instance);
        const class = self.env.classes.get(instance.class);
        const span = instance.span;
        const derivation: Derivation = .{
            .builder = .{ .allocator = self.arena() },
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
            .class = instance.class,
            .method = class.methods[0],
            .itself = instance.methods[0],
            .datatype = p.datatype,
            .span = span,
        };
        const symbol = instance.methods[0];
        try self.env.annotate(symbol, .{
            .scheme = try self.methodScheme(self.env.schemeOf(class.methods[0]).?, .{
                .type = instance.type,
                .context = instance.context,
            }),
            .span = span,
        });
        return .{ .symbol = symbol, .body = try derivation.body(), .span = span };
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
        @memcpy(constraints[0..head.context.len], head.context);
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

/// Reports each instance whose class has a superclass the instance's head
/// does not admit under the instance's context. Returns whether there was
/// none.
///
/// Preconditions:
/// - Every module of the link is declared.
pub fn checkSuperclasses(gpa: Allocator, env: *const core.env.Env, sink: *diagnostic.Sink) Error!bool {
    var ok = true;
    for (env.classes.instances.items) |instance| {
        const class = env.classes.get(instance.class);
        for (class.superclasses) |super| {
            const needed = try unmet(gpa, env, instance, super) orelse continue;
            ok = false;
            try sink.report(
                .invalid_instance,
                instance.span,
                "`{s} {f}` needs `{s} {f}`",
                .{
                    class.name.name,
                    instance.type.operand(),
                    env.classes.spelling(needed.class),
                    needed.type.operand(),
                },
            );
        }
    }
    return ok;
}

/// The part of `super` at `instance`'s head that its context does not
/// supply, if any.
fn unmet(gpa: Allocator, env: *const core.env.Env, instance: classes.Instance, super: classes.ClassId) Error!?types.TypeClassConstraint {
    var leaves: std.ArrayList(types.TypeClassConstraint) = .empty;
    defer leaves.deinit(gpa);
    if (try classes.reduce(&env.classes, super, instance.type, Bound{}, Leaves{ .gpa = gpa, .out = &leaves })) |culprit| {
        return .{ .class = super, .type = culprit };
    }
    for (leaves.items) |leaf| {
        if (!env.classes.entailedBy(instance.context, leaf)) return leaf;
    }
    return null;
}

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

/// Types over bound variables, with no metavariables to follow.
const Bound = struct {
    pub fn resolve(_: Bound, t: types.Type) types.Type {
        return t;
    }

    pub fn normalize(_: Bound, t: types.Type) error{}!types.Type {
        var current = t;
        while (current == .alias) current = current.alias.expansion;
        return current;
    }
};

/// Collects the constraints a reduction leaves on bound variables.
const Leaves = struct {
    gpa: Allocator,
    out: *std.ArrayList(types.TypeClassConstraint),

    pub const Error = Allocator.Error;

    pub fn leaf(self: Leaves, class: classes.ClassId, t: types.Type) Allocator.Error!void {
        try self.out.append(self.gpa, .{ .class = class, .type = t });
    }
};
