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

/// How a class's constraint is discharged at run time.
pub const Evidence = enum {
    /// Handled by the machine on the value. No dictionary exists.
    builtin,
    /// Entailed by an instance, and passed as a dictionary.
    dictionary,
};

pub const Class = struct {
    name: symbols.QualifiedName,
    superclasses: []const ClassId = &.{},
    /// Method symbols, in declaration order.
    methods: []const symbols.SymbolId = &.{},
    /// `dict[C]`, the constructor of this class's dictionaries: one field per
    /// selector, then one per method. Null for a class with built-in
    /// evidence, and for a reservation the prelude has not filled in.
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

pub const Instance = struct {
    class: ClassId,
    /// A datatype applied to distinct variables, bound in order from 0.
    type: types.Type,
    /// Constraints over the head's variables. Those with dictionary evidence
    /// are the dictionary's parameters, in order.
    context: []const types.TypeClassConstraint,
    /// Each method's implementation, in class method order.
    methods: []const symbols.SymbolId,
    /// `instance[C,T]`, the global holding this instance's dictionary. Null
    /// when its class has built-in evidence. Set by `Env.declareInstance`.
    dictionary: ?symbols.SymbolId,
    module: symbols.ModuleId,
    span: diagnostic.Span = .unknown,

    /// Returns the datatype the instance is declared at.
    pub fn head(self: Instance) symbols.TypeId {
        return self.type.constructor.name;
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

    /// Reserves the classes `ClassId` names, in the prelude, at the ids it
    /// names them by. `Serial` is complete. The prelude's own declarations of
    /// `Eq` and `Ord` fill in the rest.
    pub fn reserveBuiltins(self: *Registry) Allocator.Error!void {
        for ([_][]const u8{ "Eq", "Ord", "Serial" }, 0..) |name, i| {
            const id = try self.declare(.{ .name = .{ .module = .prelude, .name = name } });
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

    /// The reservation the prelude's declaration of `name` fills in, if it is
    /// one and nothing has filled it yet.
    pub fn reservation(self: *const Registry, name: []const u8) ?ClassId {
        const id = self.lookup(.prelude, name) orelse return null;
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

    /// How many constraints of `context` have dictionary evidence.
    pub fn dictionaryCount(self: *const Registry, context: []const types.TypeClassConstraint) usize {
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

    /// Whether a constraint of `givens` on `wanted`'s type entails it.
    pub fn entailedBy(self: *const Registry, givens: []const types.TypeClassConstraint, wanted: types.TypeClassConstraint) bool {
        for (givens) |given| {
            if (std.meta.eql(given.type, wanted.type) and self.entails(given.class, wanted.class)) return true;
        }
        return false;
    }

    /// Moves to the front of `context`, in order, each constraint no other
    /// constraint of it entails. Returns how many there are.
    pub fn pruneEntailed(self: *const Registry, context: []types.TypeClassConstraint) usize {
        var kept: usize = 0;
        for (context, 0..) |c, i| {
            if (self.entailedBy(context[0..i], c) or self.entailedBy(context[i + 1 ..], c)) continue;
            context[kept] = c;
            kept += 1;
        }
        return kept;
    }

    /// Appends to `out` the selectors that take a dictionary of `from` to one
    /// of `to`, innermost first. Returns false, leaving `out` as it was, when
    /// `from` does not entail `to` through superclasses with dictionaries.
    pub fn superclassPath(
        self: *const Registry,
        from: ClassId,
        to: ClassId,
        out: *std.ArrayList(symbols.SymbolId),
        gpa: Allocator,
    ) Allocator.Error!bool {
        if (from == to) return true;
        for (self.get(from).selectors) |selector| {
            const mark = out.items.len;
            try out.append(gpa, selector.symbol);
            if (try self.superclassPath(selector.superclass, to, out, gpa)) return true;
            out.shrinkRetainingCapacity(mark);
        }
        return false;
    }
};

/// How many variables an instance head of type `t` is over.
pub fn parameterCount(t: types.Type) u8 {
    return switch (t) {
        .constructor => |c| @intCast(c.arguments.len),
        else => 0,
    };
}

/// Reduces `class t` to the constraints on its leaves it holds under, through
/// instances, handing each to `sink.leaf`.
///
/// `view` supplies:
/// - `resolve(t) Type`: `t` with every solved metavariable at its head
///   followed
/// - `expand(t) Type`: `resolve`, also stripping every alias at the head
///
/// `sink` supplies `leaf(class, t) !void`, for a constraint on a
/// metavariable or bound variable.
///
/// Returns the first refuted part of `t`, if any, written as `t` writes it.
pub fn reduce(
    registry: *const Registry,
    class: ClassId,
    t: types.Type,
    view: anytype,
    sink: anytype,
) @TypeOf(sink).Error!?types.Type {
    const written = view.resolve(t);
    const expanded = view.expand(written);
    switch (expanded) {
        .meta, .variable => try sink.leaf(class, expanded),
        .alias => unreachable,
        .function => return written,
        .constructor => |c| {
            const found = registry.instanceFor(class, c.name) orelse return written;
            for (registry.instance(found).context) |needed| {
                const argument = c.arguments[needed.type.variable];
                if (try reduce(registry, needed.class, argument, view, sink)) |culprit| return culprit;
            }
        },
        .record => |r| switch (class) {
            // A row holds when every field it comes to have does.
            .eq, .serial => {
                for (r.fields) |f| {
                    if (try reduce(registry, class, f.type.*, view, sink)) |culprit| return culprit;
                }
                if (r.rest) |rest| return try reduce(registry, class, rest.*, view, sink);
            },
            else => return written,
        },
    }
    return null;
}
