//! A module's type-level declarations while their kinds are inferred.

const std = @import("std");
const core = @import("../core.zig");
const types = core.types;
const Inference = core.kinds.Inference;

const Allocator = std.mem.Allocator;

/// A module's own datatypes, aliases and classes while their kinds are
/// inferred together, with what depends on those kinds held back. The
/// translator reads a datatype's parameter kinds, an alias or a class's
/// parameter kind here before the registry. `commit` solves every kind,
/// defaulting to `Type`, and writes all of it to the environment.
pub const Group = struct {
    inference: Inference,
    datatypes: std.AutoArrayHashMapUnmanaged(core.datatypes.TypeId, []const types.Kind) = .empty,
    /// By name, in the order they are declared.
    aliases: std.StringArrayHashMapUnmanaged(*const core.datatypes.Alias) = .empty,
    classes: std.AutoArrayHashMapUnmanaged(core.classes.ClassId, types.Kind) = .empty,
    /// Each datatype's constructors, whose schemes take its parameter kinds.
    constructors: std.ArrayList(Constructors) = .empty,
    methods: std.ArrayList(Method) = .empty,

    const Constructors = struct { id: core.datatypes.TypeId, constructors: []const core.datatypes.Constructor };
    const Method = struct { symbol: core.SymbolId, scheme: types.Scheme };

    pub fn init(arena: Allocator, gpa: Allocator) Group {
        return .{ .inference = .init(arena, gpa) };
    }

    pub fn deinit(self: *Group) void {
        const gpa = self.inference.gpa;
        self.datatypes.deinit(gpa);
        self.aliases.deinit(gpa);
        self.classes.deinit(gpa);
        self.constructors.deinit(gpa);
        self.methods.deinit(gpa);
        self.inference.deinit();
    }

    /// Adds datatype `id` of `count` parameters, each of a kind to infer.
    pub fn declare(self: *Group, id: core.datatypes.TypeId, count: usize) Allocator.Error!void {
        const parameters = try self.inference.arena.alloc(types.Kind, count);
        for (parameters) |*kind| kind.* = try self.inference.fresh();
        try self.datatypes.put(self.inference.gpa, id, parameters);
    }

    /// Holds `constructors` of datatype `id` until its kinds are solved.
    pub fn setConstructors(self: *Group, id: core.datatypes.TypeId, constructors: []const core.datatypes.Constructor) Allocator.Error!void {
        try self.constructors.append(self.inference.gpa, .{ .id = id, .constructors = constructors });
    }

    /// The kind of class `id`'s parameter, solved or not.
    pub fn classKind(self: *const Group, id: core.classes.ClassId, registry: *const core.classes.Registry) types.Kind {
        return self.classes.get(id) orelse registry.get(id).parameter;
    }

    /// Adds class `id`, its parameter's kind still to infer.
    pub fn declareClass(self: *Group, id: core.classes.ClassId) Allocator.Error!void {
        try self.classes.put(self.inference.gpa, id, try self.inference.fresh());
    }

    /// Holds method `symbol`'s scheme until its kinds are solved.
    pub fn setScheme(self: *Group, symbol: core.SymbolId, scheme: types.Scheme) Allocator.Error!void {
        try self.methods.append(self.inference.gpa, .{ .symbol = symbol, .scheme = scheme });
    }

    /// Adds `alias`, its kinds still to infer.
    pub fn define(self: *Group, alias: core.datatypes.Alias) Allocator.Error!void {
        const stored = try self.inference.arena.create(core.datatypes.Alias);
        stored.* = alias;
        try self.aliases.put(self.inference.gpa, alias.name, stored);
    }

    /// Solves every kind, defaulting to `Type`, and writes the group's
    /// declarations to `env`.
    pub fn commit(self: *const Group, env: *core.env.Env) Allocator.Error!void {
        const inference = &self.inference;
        for (self.datatypes.keys(), self.datatypes.values()) |id, parameters| {
            env.datatypes.setParameters(id, try inference.zonkAll(parameters));
        }
        for (self.constructors.items) |c| try env.setConstructors(c.id, c.constructors);
        for (self.aliases.values()) |alias| {
            const parameters = try inference.arena.alloc(core.datatypes.Alias.Parameter, alias.parameters.len);
            for (alias.parameters, parameters) |parameter, *slot| {
                slot.* = .{ .name = parameter.name, .kind = try inference.zonk(parameter.kind, .type) };
            }
            var solved = alias.*;
            solved.parameters = parameters;
            solved.kind = try inference.zonk(alias.kind, .type);
            try env.datatypes.defineAlias(solved);
        }
        for (self.classes.keys(), self.classes.values()) |id, kind| {
            env.classes.getMut(id).parameter = try inference.zonk(kind, .type);
        }
        for (self.methods.items) |m| {
            var scheme = m.scheme;
            scheme.variables = try inference.zonkAll(scheme.variables);
            try env.setScheme(m.symbol, scheme);
        }
    }
};
