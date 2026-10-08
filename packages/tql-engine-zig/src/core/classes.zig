//! Declared classes and their instances.

const std = @import("std");
const datatypes = @import("datatypes.zig");
const diagnostic = @import("../diagnostic.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// A class of one link. The built-in classes hold the first ids.
pub const ClassId = enum(u16) {
    eq,
    ord,
    sized,
    serial,
    _,
};

/// An instance of one link, in the order instances were declared.
pub const InstanceId = enum(u32) { _ };

/// How a class's constraint is discharged at run time.
pub const Evidence = enum {
    /// Entailed by `datatypes.ClassRow` and the operations dispatch on the
    /// value. No dictionary exists.
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
    /// selector, then one per method. Null for a built-in class.
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

/// What an instance is declared at: a primitive type, or a declared type at
/// distinct variables.
pub const Head = union(enum) {
    primitive: types.Primitive,
    datatype: symbols.TypeId,

    /// The head of `t`, or null when `t` is not a primitive or a declared
    /// type.
    ///
    /// Preconditions:
    /// - `t` is not an alias.
    pub fn of(t: types.Type) ?Head {
        return switch (t) {
            .primitive => |p| .{ .primitive = p },
            .constructor => |c| .{ .datatype = c.name },
            else => null,
        };
    }
};

pub const Instance = struct {
    class: ClassId,
    head: Head,
    /// The head applied to its variables, bound in order from 0.
    type: types.Type,
    /// Constraints over the head's variables.
    context: []const types.TypeClassConstraint,
    /// The constraints of `context` with dictionary evidence, in order: the
    /// dictionary's parameters.
    dictionary_context: []const types.TypeClassConstraint,
    /// Each method's implementation, in class method order.
    methods: []const symbols.SymbolId,
    /// `instance[C,T]`, the global holding this instance's dictionary.
    dictionary: symbols.SymbolId,
    module: symbols.ModuleId,
    span: diagnostic.Span = .unknown,
};

/// The classes and instances of one link.
pub const Registry = struct {
    allocator: Allocator,
    classes: std.ArrayList(Class) = .empty,
    by_name: symbols.QualifiedName.Map(ClassId) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    by_head: std.AutoHashMapUnmanaged(Key, InstanceId) = .empty,

    const Key = struct { class: ClassId, head: Head };

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// Declares the built-in classes in the prelude, at the ids `ClassId`
    /// names them by.
    pub fn declareBuiltins(self: *Registry) Allocator.Error!void {
        for ([_][]const u8{ "Eq", "Ord", "Sized", "Serial" }, 0..) |name, i| {
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
            .eq, .ord, .sized, .serial => .builtin,
            _ => .dictionary,
        };
    }

    /// Adds `instance`. Returns the instance already declared for its class
    /// and head instead, adding nothing, when there is one.
    pub fn addInstance(self: *Registry, declared: Instance) Allocator.Error!union(enum) { added: InstanceId, existing: InstanceId } {
        const entry = try self.by_head.getOrPut(self.allocator, .{ .class = declared.class, .head = declared.head });
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

    pub fn instanceFor(self: *const Registry, class: ClassId, head: Head) ?InstanceId {
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

    /// Whether a constraint of `givens` on `wanted`'s type entails it.
    pub fn entailedBy(self: *const Registry, givens: []const types.TypeClassConstraint, wanted: types.TypeClassConstraint) bool {
        for (givens) |given| {
            if (std.meta.eql(given.type, wanted.type) and self.entails(given.class, wanted.class)) return true;
        }
        return false;
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

/// Whether `p` admits built-in class `class`.
///
/// Preconditions:
/// - `class` has built-in evidence.
pub fn holdsForPrimitive(class: ClassId, p: types.Primitive) bool {
    return switch (class) {
        .eq => switch (p) {
            .Int, .String, .Node, .Kind => true,
            .Regex => false,
        },
        .ord => switch (p) {
            .Int, .String => true,
            .Regex, .Node, .Kind => false,
        },
        .sized => switch (p) {
            .String => true,
            .Int, .Regex, .Node, .Kind => false,
        },
        .serial => switch (p) {
            .Int, .String, .Node, .Kind => true,
            .Regex => false,
        },
        _ => unreachable,
    };
}

/// Reduces `class t` to the constraints on its leaves it holds under, handing
/// each to `sink.leaf`. A built-in class reduces by `datatypes.ClassRow` and
/// a dictionary class by its instances.
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
    declared: *const datatypes.Registry,
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
        .primitive => |p| switch (registry.evidenceOf(class)) {
            .builtin => if (!holdsForPrimitive(class, p)) return written,
            .dictionary => _ = registry.instanceFor(class, .{ .primitive = p }) orelse return written,
        },
        .constructor => |c| switch (registry.evidenceOf(class)) {
            .builtin => switch (declared.get(c.name).classes.forClass(class)) {
                .never => return written,
                // `Sized [a]` is the one that does not descend: a list has a
                // length whatever its elements are.
                .always => {},
                .fields => for (c.arguments) |argument| {
                    if (try reduce(registry, declared, class, argument, view, sink)) |culprit| return culprit;
                },
            },
            .dictionary => {
                const found = registry.instanceFor(class, .{ .datatype = c.name }) orelse return written;
                for (registry.instance(found).context) |needed| {
                    const argument = c.arguments[needed.type.variable];
                    if (try reduce(registry, declared, needed.class, argument, view, sink)) |culprit| return culprit;
                }
            },
        },
        .record => |r| switch (class) {
            // A row holds when every field it comes to have does.
            .eq, .serial => {
                for (r.fields) |f| {
                    if (try reduce(registry, declared, class, f.type.*, view, sink)) |culprit| return culprit;
                }
                if (r.rest) |rest| return try reduce(registry, declared, class, rest.*, view, sink);
            },
            else => return written,
        },
    }
    return null;
}

test "a built-in class's id is its position" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    try registry.declareBuiltins();

    try std.testing.expectEqual(ClassId.ord, registry.lookup(.prelude, "Ord").?);
    try std.testing.expectEqualStrings("Serial", registry.spelling(.serial));
    try std.testing.expectEqual(Evidence.builtin, registry.evidenceOf(.eq));
}

test "a second instance for one class and head is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    try registry.declareBuiltins();
    const describe = try registry.declare(.{ .name = .{ .module = .prelude, .name = "Describe" } });
    const at_int: Instance = .{
        .class = describe,
        .head = .{ .primitive = .Int },
        .type = types.int_type,
        .context = &.{},
        .dictionary_context = &.{},
        .methods = &.{},
        .dictionary = @enumFromInt(0),
        .module = .prelude,
    };
    const first = (try registry.addInstance(at_int)).added;
    try std.testing.expectEqual(first, (try registry.addInstance(at_int)).existing);
    try std.testing.expectEqual(first, registry.instanceFor(describe, .{ .primitive = .Int }).?);
    try std.testing.expectEqual(null, registry.instanceFor(describe, .{ .primitive = .String }));
}

test "a class entails its superclasses at any depth" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());
    try registry.declareBuiltins();
    const base = try registry.declare(.{ .name = .{ .module = .prelude, .name = "Base" } });
    const middle = try registry.declare(.{
        .name = .{ .module = .prelude, .name = "Middle" },
        .superclasses = &.{ .eq, base },
    });
    const top = try registry.declare(.{
        .name = .{ .module = .prelude, .name = "Top" },
        .superclasses = &.{middle},
    });

    try std.testing.expect(registry.entails(top, base));
    try std.testing.expect(registry.entails(top, .eq));
    try std.testing.expect(!registry.entails(base, top));
}
