//! Declared classes and their instances.

const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// A class of one link.
pub const ClassId = enum(u16) { _ };

/// An instance of one link, in the order instances were declared.
pub const InstanceId = enum(u32) { _ };

/// What a class's body names to derive it, `deriving %derive_eq;`. Each
/// defines one method, by the datatype's shape.
pub const Deriver = enum {
    derive_eq,
    derive_ord,
    derive_to_json,
    derive_functor,
    derive_foldable,
    derive_traversable,

    /// The deriver spelled `spelling`, `%` included.
    pub fn named(spelling: []const u8) ?Deriver {
        if (!std.mem.startsWith(u8, spelling, "%")) return null;
        return std.meta.stringToEnum(Deriver, spelling[1..]);
    }

    /// The spelling of the method it defines.
    pub fn method(self: Deriver) []const u8 {
        return switch (self) {
            .derive_eq => "eq",
            .derive_ord => "compare",
            .derive_to_json => "to_json",
            .derive_functor => "map",
            .derive_foldable => "foldr",
            .derive_traversable => "traverse",
        };
    }

    /// Whether it ranges over the datatype's last parameter, which the
    /// instance leaves unapplied.
    pub fn overLast(self: Deriver) bool {
        return switch (self) {
            .derive_functor, .derive_foldable, .derive_traversable => true,
            .derive_eq, .derive_ord, .derive_to_json => false,
        };
    }

    /// Whether it also builds a record's method from its fields'.
    pub fn coversRecords(self: Deriver) bool {
        return self == .derive_eq or self == .derive_to_json;
    }
};

/// A class's deriver, resolved against the class's methods.
pub const Derived = struct {
    deriver: Deriver,
    /// The index of the method it defines.
    method: u32,
    /// For `derive_traversable`, the methods of `traverse`'s applicative.
    applicative: ?Applicative = null,
};

/// The methods of the applicative a derived `traverse` rebuilds its value in.
pub const Applicative = struct {
    pure: symbols.SymbolId,
    ap: symbols.SymbolId,
};

pub const Class = struct {
    name: symbols.QualifiedName,
    /// The kind of the class's parameter.
    parameter: types.Kind = .type,
    superclasses: []const ClassId = &.{},
    /// Method symbols, in declaration order.
    methods: []const symbols.SymbolId = &.{},
    /// `default[C,m]` for each method with a default, in `methods` order.
    defaults: []const ?symbols.SymbolId = &.{},
    /// Which methods an instance must define.
    minimal: Minimal = .{ .all = &.{} },
    /// What `deriving` generates its instances with. Null for a class that
    /// cannot be derived.
    deriver: ?Derived = null,
    /// `dict[C]`, the constructor of this class's dictionaries: one field per
    /// selector, then one per method. Null for a class whose members failed
    /// to declare.
    constructor: ?symbols.SymbolId = null,
    /// One per superclass, in `superclasses` order.
    selectors: []const Selector = &.{},
    span: diagnostic.Span = .unknown,

    /// Returns the index of the method spelled `spelling`.
    pub fn methodNamed(self: Class, interner: *const symbols.Interner, spelling: []const u8) ?u32 {
        for (self.methods, 0..) |method, i| {
            if (std.mem.eql(u8, interner.spelling(method), spelling)) return @intCast(i);
        }
        return null;
    }
};

/// A formula over a class's methods, each by its index in `Class.methods`.
pub const Minimal = union(enum) {
    method: u32,
    all: []const Minimal,
    any: []const Minimal,

    /// Returns whether an instance defining the methods `defined` marks
    /// satisfies the formula.
    pub fn satisfied(self: Minimal, defined: []const bool) bool {
        return switch (self) {
            .method => |i| defined[i],
            .all => |operands| for (operands) |o| {
                if (!o.satisfied(defined)) break false;
            } else true,
            .any => |operands| for (operands) |o| {
                if (o.satisfied(defined)) break true;
            } else false,
        };
    }
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
    /// The dictionary's parameters, in order.
    context: []const Requirement,
    /// Each method's implementation, in class method order.
    methods: []const symbols.SymbolId,
    /// `instance[C,T]`, the global holding this instance's dictionary. Set by
    /// `Env.declareInstance`.
    dictionary: symbols.SymbolId,
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

    /// The deriver that builds `class`'s dictionary at a record from its
    /// fields' dictionaries. A record's dictionary has no superclass fields,
    /// so a class with superclasses has none.
    pub fn recordDeriver(self: *const Registry, class: ClassId) ?Derived {
        const c = self.get(class);
        const derived = c.deriver orelse return null;
        if (!derived.deriver.coversRecords() or c.superclasses.len > 0) return null;
        return derived;
    }

    /// The deriver of `class` when it ranges over a whole type, so a tuple
    /// has an instance of `class` when each of its components does.
    pub fn wholeTypeDeriver(self: *const Registry, class: ClassId) ?Derived {
        const derived = self.get(class).deriver orelse return null;
        return if (derived.deriver.overLast()) null else derived;
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
            if (registry.recordDeriver(class) == null) return .{ .refuted = written };
            if (r.rest == null) {
                const evidence = try gpa.alloc(E, r.fields.len);
                defer gpa.free(evidence);
                for (r.fields, evidence) |f, *slot| {
                    const solution = try solve(gpa, registry, class, f.type.*, view, givens, sink);
                    if (solution != .solved) return solution;
                    slot.* = solution.solved;
                }
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
