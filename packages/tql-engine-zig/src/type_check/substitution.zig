//! The unification state: what each metavariable has been solved to.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

/// The unification state.
pub const Substitution = struct {
    arena: Allocator,
    /// The declared types, for deciding a constraint on a constructed type.
    datatypes: *const datatypes.Registry,
    /// Indexed by `Meta`. `null` means unsolved.
    solutions: std.ArrayList(?types.Type),
    gpa: Allocator,

    pub fn init(
        gpa: Allocator,
        arena: Allocator,
        declared: *const datatypes.Registry,
    ) Substitution {
        return .{ .arena = arena, .datatypes = declared, .solutions = .empty, .gpa = gpa };
    }

    pub fn deinit(self: *Substitution) void {
        self.solutions.deinit(self.gpa);
    }

    /// A metavariable no type mentions yet.
    pub fn fresh(self: *Substitution) !types.Type {
        const id: types.Meta = @intCast(self.solutions.items.len);
        try self.solutions.append(self.gpa, null);
        return .{ .meta = id };
    }

    pub fn count(self: *const Substitution) usize {
        return self.solutions.items.len;
    }

    /// What `id` is solved to, or null if it is still unknown.
    pub fn lookup(self: *const Substitution, id: types.Meta) ?types.Type {
        return self.solutions.items[id];
    }

    /// Binds `id` to `t`.
    ///
    /// Preconditions:
    /// - `id` is unsolved.
    /// - The occurs check has passed for `id` in `t`.
    pub fn bind(self: *Substitution, id: types.Meta, t: types.Type) void {
        self.solutions.items[id] = t;
    }

    /// Follows metavariable solutions until reaching an unsolved metavariable
    /// or a constructor. Shallow: the result's *children* may still be solved
    /// metavariables.
    pub fn resolve(self: *Substitution, t: types.Type) types.Type {
        var current = t;
        while (current == .meta) {
            const solution = self.solutions.items[current.meta] orelse return current;
            // Path compression: point the head straight at what it resolves to.
            if (solution == .meta) {
                if (self.solutions.items[solution.meta]) |next| {
                    self.solutions.items[current.meta] = next;
                    current = next;
                    continue;
                }
            }
            current = solution;
        }
        return current;
    }

    /// `resolve`, applied through the whole tree. Returns `t` itself when
    /// nothing changed, so a fully-solved type costs no allocation.
    pub fn resolveDeep(self: *Substitution, t: types.Type) !types.Type {
        return self.rewrite(t, Resolved{});
    }

    /// `t` with each metavariable and bound variable replaced by
    /// `leaf.replace` of it, resolving every node first when `leaf.resolves`.
    ///
    /// Allocates in the arena only along a path where a leaf changed, and
    /// returns `t` itself when none did.
    fn rewrite(self: *Substitution, t: types.Type, leaf: anytype) Allocator.Error!types.Type {
        const head = if (@TypeOf(leaf).resolves) self.resolve(t) else t;
        switch (head) {
            .variable, .meta => return leaf.replace(head),
            .primitive => return head,
            .constructor => |c| {
                // Allocated at the first child that changes, seeded with the
                // unchanged ones before it.
                var copies: ?[]types.Type = null;
                for (c.arguments, 0..) |argument, i| {
                    const rewritten = try self.rewrite(argument, leaf);
                    if (copies) |slots| {
                        slots[i] = rewritten;
                    } else if (!std.meta.eql(rewritten, argument)) {
                        const slots = try self.arena.alloc(types.Type, c.arguments.len);
                        @memcpy(slots[0..i], c.arguments[0..i]);
                        slots[i] = rewritten;
                        copies = slots;
                    }
                }
                const changed = copies orelse return head;
                return try types.constructed(self.arena, c.name, c.spelling, changed);
            },
            .record => |fields| {
                var copies: ?[]types.Type.Field = null;
                for (fields, 0..) |f, i| {
                    const rewritten = try self.rewrite(f.type.*, leaf);
                    if (copies) |slots| {
                        slots[i] = .{ .label = f.label, .type = try types.store(self.arena, rewritten) };
                    } else if (!std.meta.eql(rewritten, f.type.*)) {
                        const slots = try self.arena.alloc(types.Type.Field, fields.len);
                        @memcpy(slots[0..i], fields[0..i]);
                        slots[i] = .{ .label = f.label, .type = try types.store(self.arena, rewritten) };
                        copies = slots;
                    }
                }
                return .{ .record = copies orelse return head };
            },
            .function => |arrow| {
                const from = try self.rewrite(arrow.from, leaf);
                const to = try self.rewrite(arrow.to, leaf);
                if (std.meta.eql(from, arrow.from) and std.meta.eql(to, arrow.to)) return head;
                return try types.func(self.arena, from, to);
            },
        }
    }

    /// Leaves every leaf as it resolves.
    const Resolved = struct {
        const resolves = true;

        fn replace(_: Resolved, head: types.Type) types.Type {
            return head;
        }
    };

    /// Replaces each metavariable in `metas` with the bound variable at its
    /// index.
    const Bound = struct {
        metas: []const types.Meta,
        const resolves = true;

        fn replace(self: Bound, head: types.Type) types.Type {
            if (head == .meta) for (self.metas, 0..) |m, index| {
                if (m == head.meta) return .{ .variable = @intCast(index) };
            };
            return head;
        }
    };

    /// Replaces each bound variable with `metas[index]`.
    const Substituted = struct {
        metas: []const types.Type,
        const resolves = false;

        fn replace(self: Substituted, head: types.Type) types.Type {
            if (head != .variable) return head;
            return self.metas[head.variable];
        }
    };

    /// Whether `id` occurs anywhere in `t`. Binding a metavariable to a type
    /// containing it would build an infinite type, so unification checks this
    /// before every bind.
    pub fn occurs(self: *Substitution, id: types.Meta, t: types.Type) bool {
        const head = self.resolve(t);
        return switch (head) {
            .meta => |other| other == id,
            .variable, .primitive => false,
            .constructor => |c| for (c.arguments) |argument| {
                if (self.occurs(id, argument)) break true;
            } else false,
            .record => |fields| for (fields) |f| {
                if (self.occurs(id, f.type.*)) break true;
            } else false,
            .function => |arrow| self.occurs(id, arrow.from) or self.occurs(id, arrow.to),
        };
    }

    /// Collects the unsolved metavariables of `t` into `out`, in first-seen
    /// order. Generalization quantifies over these minus the environment's.
    pub fn freeMetas(self: *Substitution, t: types.Type, out: *std.ArrayList(types.Meta)) !void {
        const head = self.resolve(t);
        switch (head) {
            .meta => |id| {
                for (out.items) |seen| if (seen == id) return;
                try out.append(self.gpa, id);
            },
            .variable, .primitive => {},
            .constructor => |c| for (c.arguments) |argument| try self.freeMetas(argument, out),
            .record => |fields| for (fields) |f| try self.freeMetas(f.type.*, out),
            .function => |arrow| {
                try self.freeMetas(arrow.from, out);
                try self.freeMetas(arrow.to, out);
            },
        }
    }

    /// Replaces each of `scheme`'s quantified variables with a fresh
    /// metavariable, copying the type.
    ///
    /// Returns the instantiated type together with the metavariables the bound
    /// variables became.
    pub fn instantiate(self: *Substitution, scheme: types.Scheme) !Instantiated {
        // A monomorphic scheme's type has no bound variable to replace.
        if (scheme.quantified == 0) return .{ .type = scheme.type, .metas = &.{} };
        const metas = try self.arena.alloc(types.Type, scheme.quantified);
        for (metas) |*m| m.* = try self.fresh();
        return .{
            .type = try self.instantiateWith(scheme.type, metas),
            .metas = metas,
        };
    }

    pub const Instantiated = struct {
        type: types.Type,
        /// Indexed by the bound variable's `forall` position.
        metas: []const types.Type,
    };

    /// `t` with each `.variable` replaced by `metas[index]`, for a type whose
    /// bound variables index the same `forall` a scheme was instantiated with.
    pub fn instantiateWith(self: *Substitution, t: types.Type, metas: []const types.Type) !types.Type {
        if (metas.len == 0) return t;
        return self.rewrite(t, Substituted{ .metas = metas });
    }

    /// The inverse of `instantiate`: turns the given free metavariables into
    /// bound `forall` positions, numbered by their order in `metas`.
    ///
    /// Returns `error.TooManyVariables` if `metas` has more entries than a
    /// `TypeVar` can number.
    pub fn quantify(
        self: *Substitution,
        t: types.Type,
        metas: []const types.Meta,
        constraint_list: []const types.TypeClassConstraint,
    ) (error{TooManyVariables} || Allocator.Error)!types.Scheme {
        if (metas.len > std.math.maxInt(types.TypeVar)) return error.TooManyVariables;

        const bound = try self.arena.alloc(types.TypeClassConstraint, constraint_list.len);
        for (constraint_list, bound) |c, *slot| {
            slot.* = .{ .class = c.class, .type = try self.rewrite(c.type, Bound{ .metas = metas }) };
        }

        return .{
            .quantified = @intCast(metas.len),
            .constraints = bound,
            .type = try self.rewrite(t, Bound{ .metas = metas }),
        };
    }
};
