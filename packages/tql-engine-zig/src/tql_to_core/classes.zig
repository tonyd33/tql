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
                .{ .class = id, .name = declared.name, .parameter = declared.parameter },
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
        const id = try self.env.datatypes.declare(&self.env.interner, self.module(), spelling, @intCast(count), &.{}, .{});
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

        const head = try annotation.translateInstance(self.arena(), self.gpa, declared, self.scope, self.sink);
        const head_name, const head_module: core.ModuleId = switch (head.head) {
            .primitive => |p| .{ p.spelling(), .prelude },
            .datatype => |id| .{ self.env.datatypes.get(id).name, self.env.datatypes.get(id).module },
        };
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

        const dictionary = try self.env.interner.generate(
            self.module(),
            try std.fmt.allocPrint(self.arena(), "instance[{s},{s}]", .{ class.name.name, head_name }),
            .vanilla,
        );
        var dictionary_context: std.ArrayList(types.TypeClassConstraint) = .empty;
        for (head.context) |c| {
            if (self.env.classes.evidenceOf(c.class) == .dictionary) try dictionary_context.append(self.arena(), c);
        }
        const id = switch (try self.env.classes.addInstance(.{
            .class = class_id,
            .head = head.head,
            .type = head.type,
            .context = head.context,
            .dictionary_context = dictionary_context.items,
            .methods = &.{},
            .dictionary = dictionary,
            .module = self.module(),
            .span = declared.span,
        })) {
            .added => |id| id,
            .existing => |first| {
                try self.sink.report(
                    .duplicate_instance,
                    declared.span,
                    "`{s} {s}` is already declared in `{s}`",
                    .{ class.name.name, head_name, self.env.interner.moduleName(self.env.classes.instance(first).module) },
                );
                return error.BadAnnotation;
            },
        };
        self.env.interner.setDetails(dictionary, .{ .instance = id });

        const implementations = try self.arena().alloc(core.SymbolId, class.methods.len);
        for (class.methods, defined, implementations) |method, definition, *implementation| {
            implementation.* = try self.env.interner.generate(
                self.module(),
                try std.fmt.allocPrint(self.arena(), "{s}[{s}]", .{ definition.?.name, head_name }),
                .instance_method,
            );
            try self.env.annotate(implementation.*, .{
                .scheme = try self.methodScheme(self.env.schemeOf(method).?, head),
                .span = definition.?.span,
            });
            try out.append(self.gpa, .{ .symbol = implementation.*, .definition = definition.? });
        }
        self.env.classes.instanceMut(id).methods = implementations;
    }

    /// A class method's scheme at an instance head: the head's variables
    /// come first, then the method's own, and the instance's context replaces
    /// the class's own constraint.
    fn methodScheme(self: *Linker, method: types.Scheme, head: annotation.InstanceHead) Error!types.Scheme {
        const parameters = classes.parameterCount(head.type);
        const arguments = try self.arena().alloc(types.Type, method.quantified);
        arguments[0] = head.type;
        for (arguments[1..], 0..) |*argument, i| argument.* = types.variable_type(@intCast(parameters + i));

        const constraints = try self.arena().alloc(types.TypeClassConstraint, head.context.len + method.constraints.len - 1);
        @memcpy(constraints[0..head.context.len], head.context);
        for (method.constraints[1..], constraints[head.context.len..]) |c, *slot| {
            slot.* = .{ .class = c.class, .type = try types.substitute(self.arena(), c.type, arguments) };
        }
        return .{
            .quantified = @intCast(parameters + method.quantified - 1),
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
    if (try classes.reduce(&env.classes, &env.datatypes, super, instance.type, Bound{}, Leaves{ .gpa = gpa, .out = &leaves })) |culprit| {
        return .{ .class = super, .type = culprit };
    }
    for (leaves.items) |leaf| {
        if (!env.classes.entailedBy(instance.context, leaf)) return leaf;
    }
    return null;
}

/// Types over bound variables, with no metavariables to follow.
const Bound = struct {
    pub fn resolve(_: Bound, t: types.Type) types.Type {
        return t;
    }

    pub fn expand(_: Bound, t: types.Type) types.Type {
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
