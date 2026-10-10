//! Kind inference over written types: a metavariable for each kind a first
//! use does not fix, solved by first-order unification, and defaulted to
//! `Type` where nothing solves it.

const std = @import("std");
const core = @import("../core.zig");
const types = core.types;

const Allocator = std.mem.Allocator;

pub const Inference = struct {
    /// Where arrows built by `zonk` live.
    arena: Allocator,
    gpa: Allocator,
    /// Indexed by `KindMeta`. `null` means unsolved.
    solutions: std.ArrayList(?types.Kind) = .empty,

    pub fn init(arena: Allocator, gpa: Allocator) Inference {
        return .{ .arena = arena, .gpa = gpa };
    }

    pub fn deinit(self: *Inference) void {
        self.solutions.deinit(self.gpa);
    }

    /// A metavariable no kind mentions yet.
    pub fn fresh(self: *Inference) Allocator.Error!types.Kind {
        const id: types.KindMeta = @intCast(self.solutions.items.len);
        try self.solutions.append(self.gpa, null);
        return .{ .meta = id };
    }

    /// Follows solutions until reaching an unsolved metavariable or a
    /// constructor.
    pub fn resolve(self: *const Inference, k: types.Kind) types.Kind {
        var current = k;
        while (current == .meta) current = self.solutions.items[current.meta] orelse return current;
        return current;
    }

    /// Makes `a` and `b` equal. Returns false when they cannot be, with any
    /// solution found on the way kept.
    pub fn unify(self: *Inference, a: types.Kind, b: types.Kind) bool {
        const left = self.resolve(a);
        const right = self.resolve(b);
        if (left == .meta) return self.bind(left.meta, right);
        if (right == .meta) return self.bind(right.meta, left);
        return switch (left) {
            .type, .row => std.meta.activeTag(left) == std.meta.activeTag(right),
            .arrow => |x| right == .arrow and self.unify(x.from, right.arrow.from) and self.unify(x.to, right.arrow.to),
            .meta => unreachable,
        };
    }

    fn bind(self: *Inference, id: types.KindMeta, k: types.Kind) bool {
        if (k == .meta and k.meta == id) return true;
        if (self.occurs(id, k)) return false;
        self.solutions.items[id] = k;
        return true;
    }

    fn occurs(self: *const Inference, id: types.KindMeta, k: types.Kind) bool {
        return switch (self.resolve(k)) {
            .type, .row => false,
            .arrow => |x| self.occurs(id, x.from) or self.occurs(id, x.to),
            .meta => |other| other == id,
        };
    }

    /// `k` with every solution substituted, and each metavariable left
    /// unsolved kept when `default` is null or replaced by it otherwise.
    pub fn zonk(self: *const Inference, k: types.Kind, default: ?types.Kind) Allocator.Error!types.Kind {
        return switch (self.resolve(k)) {
            .type => .type,
            .row => .row,
            .meta => |id| default orelse .{ .meta = id },
            .arrow => |x| try types.Kind.arrows(self.arena, &.{try self.zonk(x.from, default)}, try self.zonk(x.to, default)),
        };
    }

    /// `zonk` over each of `kinds`, defaulting to `Type`, into a new slice.
    pub fn zonkAll(self: *const Inference, kinds: []const types.Kind) Allocator.Error![]const types.Kind {
        const out = try self.arena.alloc(types.Kind, kinds.len);
        for (kinds, out) |k, *slot| slot.* = try self.zonk(k, .type);
        return out;
    }
};

/// A module's own datatypes and aliases while their kinds are inferred
/// together. The translator reads a datatype's parameter kinds and an alias
/// here before the registry, which takes them once they are solved.
pub const Group = struct {
    inference: Inference,
    datatypes: std.AutoHashMapUnmanaged(core.datatypes.TypeId, []const types.Kind) = .empty,
    /// By name, in the order they are declared.
    aliases: std.StringArrayHashMapUnmanaged(*const core.datatypes.Alias) = .empty,

    pub fn init(arena: Allocator, gpa: Allocator) Group {
        return .{ .inference = .init(arena, gpa) };
    }

    pub fn deinit(self: *Group) void {
        const gpa = self.inference.gpa;
        self.datatypes.deinit(gpa);
        self.aliases.deinit(gpa);
        self.inference.deinit();
    }

    /// Adds datatype `id` of `count` parameters, each of a kind to infer.
    pub fn declare(self: *Group, id: core.datatypes.TypeId, count: usize) Allocator.Error!void {
        const parameters = try self.inference.arena.alloc(types.Kind, count);
        for (parameters) |*kind| kind.* = try self.inference.fresh();
        try self.datatypes.put(self.inference.gpa, id, parameters);
    }

    /// Adds `alias`, its kinds still to infer.
    pub fn define(self: *Group, alias: core.datatypes.Alias) Allocator.Error!void {
        const stored = try self.inference.arena.create(core.datatypes.Alias);
        stored.* = alias;
        try self.aliases.put(self.inference.gpa, alias.name, stored);
    }

    /// `alias` with every kind solved, defaulting to `Type`.
    pub fn solved(self: *const Group, alias: *const core.datatypes.Alias) Allocator.Error!core.datatypes.Alias {
        const parameters = try self.inference.arena.alloc(core.datatypes.Alias.Parameter, alias.parameters.len);
        for (alias.parameters, parameters) |parameter, *slot| {
            slot.* = .{ .name = parameter.name, .kind = try self.inference.zonk(parameter.kind, .type) };
        }
        var result = alias.*;
        result.parameters = parameters;
        result.kind = try self.inference.zonk(alias.kind, .type);
        return result;
    }
};
