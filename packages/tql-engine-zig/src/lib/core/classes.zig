//! Declared classes and their instances.

const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// A class of one link. The classes the engine names hold the first ids.
pub const ClassId = enum(u16) {
    eq,
    ord,
    serial,
    _,
};

/// An instance of one link, in the order instances were declared.
pub const InstanceId = enum(u32) { _ };

/// The classes `deriving` accepts.
pub const derivable = [_]ClassId{ .eq, .ord, .serial };

/// Whether a record has an instance of `class` when each of its fields does.
pub fn coversRecords(class: ClassId) bool {
    return class == .eq or class == .serial;
}

/// How a class's constraint is discharged at run time.
pub const Evidence = enum {
    /// Handled by the machine on the value. No dictionary exists.
    builtin,
    /// Entailed by an instance, and passed as a dictionary.
    dictionary,
};

pub const Class = struct {
    name: symbols.QualifiedName,
    /// The kind of the class's parameter.
    parameter: types.Kind = .type,
    superclasses: []const ClassId = &.{},
    /// Method symbols, in declaration order.
    methods: []const symbols.SymbolId = &.{},
    /// `dict[C]`, the constructor of this class's dictionaries: one field per
    /// selector, then one per method. Null for a class with built-in
    /// evidence, and for a reservation `Prim` has not filled in.
    constructor: ?symbols.SymbolId = null,
    /// One per superclass with dictionary evidence, in `superclasses` order.
    selectors: []const Selector = &.{},
    span: diagnostic.Span = .unknown,
};

/// `super[C,S]`, which takes a dictionary of its class to one of
/// `superclass`.
pub const Selector = struct {
    superclass: ClassId,
    symbol: symbols.SymbolId,
};

/// `class a` in an instance's context, on the head's variable `a`.
pub const Requirement = struct {
    class: ClassId,
    variable: types.TypeVar,

    /// Returns `self` as a constraint on its bound variable.
    pub fn constraint(self: Requirement) types.TypeClassConstraint {
        return .{ .class = self.class, .type = types.variable_type(self.variable) };
    }
};

pub const Instance = struct {
    class: ClassId,
    /// A datatype applied to distinct variables, bound in order from 0.
    type: types.Type,
    /// Those with dictionary evidence are the dictionary's parameters, in
    /// order.
    context: []const Requirement,
    /// Each method's implementation, in class method order.
    methods: []const symbols.SymbolId,
    /// `instance[C,T]`, the global holding this instance's dictionary. Null
    /// when its class has built-in evidence. Set by `Env.declareInstance`.
    dictionary: ?symbols.SymbolId,
    module: symbols.ModuleId,
    span: diagnostic.Span = .unknown,

    /// Returns the datatype the instance is declared at.
    pub fn head(self: Instance) symbols.TypeId {
        return types.asApplied(self.type).?.name();
    }
};

/// The classes and instances of one link.
pub const Registry = struct {
    allocator: Allocator,
    classes: std.ArrayList(Class) = .empty,
    by_name: symbols.QualifiedName.Map(ClassId) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    by_head: std.AutoHashMapUnmanaged(Key, InstanceId) = .empty,

    const Key = struct { class: ClassId, head: symbols.TypeId };

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// A copy allocated from `allocator`, sharing the classes' contents.
    pub fn clone(self: *const Registry, allocator: Allocator) Allocator.Error!Registry {
        return .{
            .allocator = allocator,
            .classes = try self.classes.clone(allocator),
            .by_name = try self.by_name.clone(allocator),
            .instances = try self.instances.clone(allocator),
            .by_head = try self.by_head.clone(allocator),
        };
    }

    /// Reserves the classes `ClassId` names, in `Prim`, at the ids it names
    /// them by. `Serial` is complete. `Prim`'s own declarations of `Eq` and
    /// `Ord` fill in the rest.
    pub fn reserveBuiltins(self: *Registry) Allocator.Error!void {
        for ([_][]const u8{ "Eq", "Ord", "Serial" }, 0..) |name, i| {
            const id = try self.declare(.{ .name = .{ .module = .prim, .name = name } });
            std.debug.assert(@intFromEnum(id) == i);
        }
    }

    /// `class.name` and everything `class` points to must outlive the
    /// registry.
    pub fn declare(self: *Registry, class: Class) Allocator.Error!ClassId {
        const id: ClassId = @enumFromInt(self.classes.items.len);
        try self.classes.append(self.allocator, class);
        try self.by_name.put(self.allocator, class.name, id);
        return id;
    }

    pub fn get(self: *const Registry, id: ClassId) *const Class {
        return &self.classes.items[@intFromEnum(id)];
    }

    pub fn getMut(self: *Registry, id: ClassId) *Class {
        return &self.classes.items[@intFromEnum(id)];
    }

    pub fn spelling(self: *const Registry, id: ClassId) []const u8 {
        return self.get(id).name.name;
    }

    /// The class `module` declares as `name`.
    pub fn lookup(self: *const Registry, module: symbols.ModuleId, name: []const u8) ?ClassId {
        return self.by_name.get(.{ .module = module, .name = name });
    }

    pub fn evidenceOf(_: *const Registry, id: ClassId) Evidence {
        return switch (id) {
            .serial => .builtin,
            else => .dictionary,
        };
    }

    /// The reservation `Prim`'s declaration of `name` fills in, if it is
    /// one and nothing has filled it yet.
    pub fn reservation(self: *const Registry, name: []const u8) ?ClassId {
        const id = self.lookup(.prim, name) orelse return null;
        switch (id) {
            .eq, .ord => {},
            else => return null,
        }
        if (self.get(id).constructor != null) return null;
        return id;
    }

    pub const Addition = union(enum) { added: InstanceId, existing: InstanceId };

    /// Adds `instance`. Returns the instance already declared for its class
    /// and head instead, adding nothing, when there is one.
    pub fn addInstance(self: *Registry, declared: Instance) Allocator.Error!Addition {
        const entry = try self.by_head.getOrPut(self.allocator, .{ .class = declared.class, .head = declared.head() });
        if (entry.found_existing) return .{ .existing = entry.value_ptr.* };
        const id: InstanceId = @enumFromInt(self.instances.items.len);
        try self.instances.append(self.allocator, declared);
        entry.value_ptr.* = id;
        return .{ .added = id };
    }

    pub fn instance(self: *const Registry, id: InstanceId) *const Instance {
        return &self.instances.items[@intFromEnum(id)];
    }

    pub fn instanceMut(self: *Registry, id: InstanceId) *Instance {
        return &self.instances.items[@intFromEnum(id)];
    }

    pub fn instanceFor(self: *const Registry, class: ClassId, head: symbols.TypeId) ?InstanceId {
        return self.by_head.get(.{ .class = class, .head = head });
    }

    /// How many constraints of `context`, each with a `class`, have
    /// dictionary evidence.
    pub fn dictionaryCount(self: *const Registry, context: anytype) usize {
        var count: usize = 0;
        for (context) |c| {
            if (self.evidenceOf(c.class) == .dictionary) count += 1;
        }
        return count;
    }

    /// Whether `from`, or a superclass of it at any depth, is `to`.
    pub fn entails(self: *const Registry, from: ClassId, to: ClassId) bool {
        if (from == to) return true;
        for (self.get(from).superclasses) |super| {
            if (self.entails(super, to)) return true;
        }
        return false;
    }
};

/// A constraint in scope, and its evidence.
pub fn Given(comptime E: type) type {
    return struct {
        class: ClassId,
        type: types.Type,
        evidence: E,
    };
}

pub fn Solution(comptime E: type) type {
    return union(enum) {
        solved: E,
        /// The part of the wanted's type no instance covers, written as the
        /// wanted writes it.
        refuted: types.Type,
        /// A leaf neither the givens nor `sink.leaf` discharge.
        stuck: types.TypeClassConstraint,
    };
}

/// Solves `class t`, building its evidence: from a given, directly or
/// through its superclasses, else from the instance at `t`'s head with its
/// context solved the same way. A closed record is solved field by field
/// when `class` covers records.
///
/// A leaf no given solves goes to `sink.leaf`. A leaf is a constraint on a
/// metavariable or bound variable, on one applied to types, or on an open
/// record whose known fields are not refuted.
///
/// `view` supplies:
/// - `resolve(t) Type`: `t` with every solved metavariable at its head
///   followed
/// - `normalize(t) !Type`: `resolve`, also stripping every alias at the head,
///   rebuilding an application whose head is solved, and following a
///   record's row to the end
/// - `resolveDeep(t) !Type`: `t` with every solved metavariable followed, for
///   comparing against a given
///
/// `sink` supplies the type `Evidence` and:
/// - `select(selector, of) !Evidence`: a superclass selected from `of`
/// - `instance(id, context) !Evidence`: instance `id` at the evidence for
///   each requirement of its context, in order
/// - `record(class, fields, evidence) !Evidence`: a closed record's, from
///   each field's
/// - `builtin(class) Evidence`: for a class the machine handles
/// - `leaf(class, t) !?Evidence`: for a leaf no given solves, or null when
///   it is stuck
pub fn solve(
    gpa: Allocator,
    registry: *const Registry,
    class: ClassId,
    t: types.Type,
    view: anytype,
    givens: anytype,
    sink: anytype,
) (@TypeOf(sink).Error || Allocator.Error)!Solution(@TypeOf(sink).Evidence) {
    const E = @TypeOf(sink).Evidence;
    if (givens.len > 0) {
        const wanted = try view.resolveDeep(t);
        for (givens) |g| {
            if (!registry.entails(g.class, class)) continue;
            if (!types.eql(try view.resolveDeep(g.type), wanted)) continue;
            if (registry.evidenceOf(class) == .builtin) return .{ .solved = sink.builtin(class) };
            return .{ .solved = try superclass(registry, g.class, class, g.evidence, sink) };
        }
    }

    const written = view.resolve(t);
    const expanded = try view.normalize(written);
    switch (expanded) {
        .meta, .variable, .skolem, .application => {},
        .alias => unreachable,
        .constructor, .function => {
            const c = types.asApplied(expanded).?;
            const found = registry.instanceFor(class, c.name()) orelse return .{ .refuted = written };
            const context = registry.instance(found).context;
            const evidence = try gpa.alloc(E, context.len);
            defer gpa.free(evidence);
            for (context, evidence) |needed, *slot| {
                const solution = try solve(gpa, registry, needed.class, c.argument(needed.variable), view, givens, sink);
                if (solution != .solved) return solution;
                slot.* = solution.solved;
            }
            return .{ .solved = try sink.instance(found, evidence) };
        },
        .record => |r| {
            if (!coversRecords(class)) return .{ .refuted = written };
            if (r.rest == null) {
                const evidence = try gpa.alloc(E, r.fields.len);
                defer gpa.free(evidence);
                for (r.fields, evidence) |f, *slot| {
                    const solution = try solve(gpa, registry, class, f.type.*, view, givens, sink);
                    if (solution != .solved) return solution;
                    slot.* = solution.solved;
                }
                if (registry.evidenceOf(class) == .builtin) return .{ .solved = sink.builtin(class) };
                return .{ .solved = try sink.record(class, r.fields, evidence) };
            }
            // An open record's known fields can refute it, and the rest is
            // decided once its row is.
            for (r.fields) |f| {
                switch (try solve(gpa, registry, class, f.type.*, view, @as([]const Given(void), &.{}), Check{ .assume = {} })) {
                    .refuted => |culprit| return .{ .refuted = culprit },
                    .solved, .stuck => {},
                }
            }
        },
    }
    if (try sink.leaf(class, expanded)) |e| return .{ .solved = e };
    return .{ .stuck = .{ .class = class, .type = expanded } };
}

/// The evidence for `to`, a superclass of `from` at any depth, selected
/// from `of`, evidence for `from`.
fn superclass(registry: *const Registry, from: ClassId, to: ClassId, of: anytype, sink: anytype) !@TypeOf(of) {
    if (from == to) return of;
    for (registry.get(from).selectors) |selector| {
        if (!registry.entails(selector.superclass, to)) continue;
        return try superclass(registry, selector.superclass, to, try sink.select(selector.symbol, of), sink);
    }
    unreachable;
}

/// A `solve` view of types over bound variables, with no metavariables to
/// follow.
pub const Bound = struct {
    pub fn resolve(_: Bound, t: types.Type) types.Type {
        return t;
    }

    pub fn normalize(_: Bound, t: types.Type) error{}!types.Type {
        return types.unalias(t);
    }

    pub fn resolveDeep(_: Bound, t: types.Type) error{}!types.Type {
        return t;
    }
};

/// How many variables an instance head of type `t` is over.
pub fn parameterCount(t: types.Type) u8 {
    const c = types.asApplied(t) orelse return 0;
    return @intCast(c.arity());
}

/// A `solve` sink that builds no evidence, by what it makes of a leaf no
/// given solves.
pub const Check = union(enum) {
    /// Solved, for asking only whether a constraint is refuted.
    assume,
    /// Stuck, for asking whether the givens alone solve a constraint.
    refuse,
    /// Solved, and appended to `out`.
    collect: struct {
        gpa: Allocator,
        out: *std.ArrayList(types.TypeClassConstraint),
    },

    pub const Evidence = void;
    pub const Error = Allocator.Error;

    pub fn select(_: Check, _: symbols.SymbolId, _: void) Error!void {}
    pub fn instance(_: Check, _: InstanceId, _: []const void) Error!void {}
    pub fn record(_: Check, _: ClassId, _: []const types.Type.Field, _: []const void) Error!void {}
    pub fn builtin(_: Check, _: ClassId) void {}

    pub fn leaf(self: Check, class: ClassId, t: types.Type) Error!?void {
        switch (self) {
            .assume => return {},
            .refuse => return null,
            .collect => |c| {
                try c.out.append(c.gpa, .{ .class = class, .type = t });
                return {};
            },
        }
    }
};

/// Appends each of `constraints` to `out` as a given with no evidence.
pub fn assume(
    gpa: Allocator,
    constraints: []const types.TypeClassConstraint,
    out: *std.ArrayList(Given(void)),
) Allocator.Error!void {
    for (constraints) |c| try out.append(gpa, .{ .class = c.class, .type = c.type, .evidence = {} });
}

/// Moves to the front of `context`, in order, each constraint the others do
/// not solve as givens. Returns how many there are.
///
/// Preconditions:
/// - Each constraint of `context` is a leaf.
pub fn prune(
    gpa: Allocator,
    registry: *const Registry,
    context: []types.TypeClassConstraint,
    view: anytype,
) Allocator.Error!usize {
    var givens: std.ArrayList(Given(void)) = .empty;
    defer givens.deinit(gpa);
    var kept: usize = 0;
    for (context, 0..) |c, i| {
        givens.clearRetainingCapacity();
        try assume(gpa, context[0..kept], &givens);
        try assume(gpa, context[i + 1 ..], &givens);
        switch (try solve(gpa, registry, c.class, c.type, view, givens.items, Check{ .refuse = {} })) {
            .solved => continue,
            .refuted, .stuck => {},
        }
        context[kept] = c;
        kept += 1;
    }
    return kept;
}
