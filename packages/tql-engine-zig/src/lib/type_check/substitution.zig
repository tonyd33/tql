//! The unification state: what each metavariable has been solved to.

const std = @import("std");
const core = @import("../core.zig");
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

/// What `rewrite` does at a metavariable or bound variable.
const Leaf = union(enum) {
    /// Leaves every leaf as it resolves.
    resolved,
    /// Replaces each metavariable listed with the bound variable at its
    /// index.
    bound: []const types.Meta,
    /// Replaces one metavariable with a type.
    assigned: struct { meta: types.Meta, type: types.Type },

    fn replace(self: Leaf, head: types.Type) types.Type {
        switch (self) {
            .resolved => {},
            .assigned => |a| if (head == .meta and head.meta == a.meta) return a.type,
            .bound => |metas| if (head == .meta) {
                if (std.mem.indexOfScalar(types.Meta, metas, head.meta)) |index| return .{ .variable = @intCast(index) };
            },
        }
        return head;
    }
};

/// Resolves every node and flattens every record as the rewrite reaches it.
const Rewriter = struct {
    subst: *Substitution,
    leaf: Leaf,

    pub fn head(self: Rewriter, t: types.Type) types.Type {
        return self.subst.resolve(t);
    }

    pub fn record(self: Rewriter, r: types.Type.Record) Allocator.Error!types.Type.Record {
        return try self.subst.flatten(r);
    }

    pub fn replace(self: Rewriter, t: types.Type) types.Type {
        return self.leaf.replace(t);
    }
};

/// The unification state.
pub const Substitution = struct {
    arena: Allocator,
    /// The declared types, for deciding a constraint on a constructed type.
    datatypes: *const datatypes.Registry,
    /// The declared classes and instances, for deciding a constraint.
    classes: *const classes.Registry,
    /// Indexed by `Meta`. `null` means unsolved.
    solutions: std.ArrayList(?types.Type),
    /// Indexed by `Meta`.
    kinds: std.ArrayList(types.Kind),
    gpa: Allocator,

    pub fn init(
        gpa: Allocator,
        arena: Allocator,
        declared: *const datatypes.Registry,
        registry: *const classes.Registry,
    ) Substitution {
        return .{ .arena = arena, .datatypes = declared, .classes = registry, .solutions = .empty, .kinds = .empty, .gpa = gpa };
    }

    pub fn deinit(self: *Substitution) void {
        self.solutions.deinit(self.gpa);
        self.kinds.deinit(self.gpa);
    }

    /// A metavariable of kind `kind` no type mentions yet.
    pub fn fresh(self: *Substitution, kind: types.Kind) !types.Type {
        const id: types.Meta = @intCast(self.solutions.items.len);
        try self.solutions.append(self.gpa, null);
        try self.kinds.append(self.gpa, kind);
        return .{ .meta = id };
    }

    pub fn kindOf(self: *const Substitution, id: types.Meta) types.Kind {
        return self.kinds.items[id];
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

    /// `resolve`, also stripping every alias at the head. The result is
    /// never `.alias`.
    pub fn expand(self: *Substitution, t: types.Type) types.Type {
        var current = self.resolve(t);
        while (current == .alias) current = self.resolve(current.alias.expansion);
        return current;
    }

    /// `expand`, also rebuilding an application whose head is solved as its
    /// head's solution at its argument. An `.application` in the result has
    /// an unsolved head.
    pub fn normalize(self: *Substitution, t: types.Type) Allocator.Error!types.Type {
        const head = self.expand(t);
        if (head != .application) return head;
        const applied = try self.normalize(head.application.head);
        if (std.meta.eql(applied, head.application.head)) return head;
        return try types.apply(self.arena, applied, head.application.argument);
    }

    /// `r` with its row followed to the end: every field reachable through
    /// `rest`, sorted by label, and a `rest` that is null, an unsolved
    /// metavariable or a bound variable.
    ///
    /// Shallow in the field types. Returns `r` itself when its row is already
    /// at the end.
    pub fn flatten(self: *Substitution, r: types.Type.Record) Allocator.Error!types.Type.Record {
        var fields = r.fields;
        var rest = r.rest orelse return r;
        while (true) {
            const head = self.expand(rest.*);
            switch (head) {
                .record => |more| {
                    fields = try mergeFields(self.arena, fields, more.fields);
                    rest = more.rest orelse return .{ .fields = fields };
                },
                else => {
                    if (fields.ptr == r.fields.ptr and std.meta.eql(head, r.rest.?.*)) return r;
                    return .{ .fields = fields, .rest = try types.store(self.arena, head) };
                },
            }
        }
    }

    /// `resolve`, applied through the whole tree. Returns `t` itself when
    /// nothing changed, so a fully-solved type costs no allocation.
    pub fn resolveDeep(self: *Substitution, t: types.Type) !types.Type {
        return self.rewrite(t, .resolved);
    }

    /// `t` with each metavariable and bound variable replaced by
    /// `leaf.replace` of it, resolving every node first.
    ///
    /// Allocates in the arena only along a path where a leaf changed, and
    /// returns `t` itself when none did.
    fn rewrite(self: *Substitution, t: types.Type, leaf: Leaf) Allocator.Error!types.Type {
        return try types.rewrite(self.arena, t, Rewriter{ .subst = self, .leaf = leaf });
    }

    /// Whether `id` occurs anywhere in `t`. Binding a metavariable to a type
    /// containing it would build an infinite type, so unification checks this
    /// before every bind.
    pub fn occurs(self: *Substitution, id: types.Meta, t: types.Type) bool {
        const head = self.expand(t);
        return switch (head) {
            .meta => |other| other == id,
            .variable => false,
            .alias => unreachable,
            .constructor => |c| for (c.arguments) |argument| {
                if (self.occurs(id, argument)) break true;
            } else false,
            .record => |r| for (r.fields) |f| {
                if (self.occurs(id, f.type.*)) break true;
            } else if (r.rest) |rest| self.occurs(id, rest.*) else false,
            .function => |arrow| self.occurs(id, arrow.from) or self.occurs(id, arrow.to),
            .application => |a| self.occurs(id, a.head) or self.occurs(id, a.argument),
        };
    }

    /// Collects the unsolved metavariables of `t` into `out`, in first-seen
    /// order. Generalization quantifies over these minus the environment's.
    pub fn freeMetas(self: *Substitution, t: types.Type, out: *std.ArrayList(types.Meta)) !void {
        const head = self.resolve(t);
        switch (head) {
            .meta => |id| {
                if (std.mem.indexOfScalar(types.Meta, out.items, id) != null) return;
                try out.append(self.gpa, id);
            },
            .variable => {},
            .constructor => |c| for (c.arguments) |argument| try self.freeMetas(argument, out),
            .record => |r| {
                for (r.fields) |f| try self.freeMetas(f.type.*, out);
                if (r.rest) |rest| try self.freeMetas(rest.*, out);
            },
            .function => |arrow| {
                try self.freeMetas(arrow.from, out);
                try self.freeMetas(arrow.to, out);
            },
            .application => |a| {
                try self.freeMetas(a.head, out);
                try self.freeMetas(a.argument, out);
            },
            // Arguments first, in the order they print.
            .alias => |a| {
                for (a.arguments) |argument| try self.freeMetas(argument, out);
                try self.freeMetas(a.expansion, out);
            },
        }
    }

    /// Replaces each of `scheme`'s quantified variables with a fresh
    /// metavariable, copying the type.
    ///
    /// Postconditions:
    /// - The type has no bound variable.
    ///
    /// Returns the instantiated type together with the metavariables the bound
    /// variables became.
    pub fn instantiate(self: *Substitution, scheme: types.Scheme) !Instantiated {
        const metas = try self.arena.alloc(types.Type, scheme.variables.len);
        for (metas, scheme.variables) |*m, kind| m.* = try self.fresh(kind);
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
        return types.substitute(self.arena, t, metas);
    }

    /// `t` with each of `metas` replaced by the bound variable at its index,
    /// or null when `t` has a free metavariable `metas` lacks.
    pub fn abstractOver(self: *Substitution, t: types.Type, metas: []const types.Meta) Allocator.Error!?types.Type {
        if (!try self.within(t, metas)) return null;
        return try self.rewrite(t, .{ .bound = metas });
    }

    /// `t` with metavariable `id` replaced by `by`, as if `id` were bound to
    /// it. The substitution is unchanged.
    pub fn assigned(self: *Substitution, t: types.Type, id: types.Meta, by: types.Type) Allocator.Error!types.Type {
        return try self.rewrite(t, .{ .assigned = .{ .meta = id, .type = by } });
    }

    /// Whether `t` has any of `metas` free.
    pub fn mentionsAny(self: *Substitution, t: types.Type, metas: []const types.Meta) Allocator.Error!bool {
        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.freeMetas(t, &free);
        for (free.items) |id| if (std.mem.indexOfScalar(types.Meta, metas, id) != null) return true;
        return false;
    }

    /// Whether every free metavariable of `t` is one of `metas`.
    pub fn within(self: *Substitution, t: types.Type, metas: []const types.Meta) Allocator.Error!bool {
        var free: std.ArrayList(types.Meta) = .empty;
        defer free.deinit(self.gpa);
        try self.freeMetas(t, &free);
        for (free.items) |id| if (std.mem.indexOfScalar(types.Meta, metas, id) == null) return false;
        return true;
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
            slot.* = .{ .class = c.class, .type = try self.rewrite(c.type, .{ .bound = metas }) };
        }

        const variables = try self.arena.alloc(types.Kind, metas.len);
        for (metas, variables) |id, *kind| kind.* = self.kindOf(id);
        return .{
            .variables = variables,
            .constraints = bound,
            .type = try self.rewrite(t, .{ .bound = metas }),
        };
    }
};

/// The fields of `first` and `second` in one list sorted by label. A label in
/// both keeps both, `first`'s ahead.
fn mergeFields(
    arena: Allocator,
    first: []const types.Type.Field,
    second: []const types.Type.Field,
) Allocator.Error![]const types.Type.Field {
    if (second.len == 0) return first;
    if (first.len == 0) return second;
    const merged = try arena.alloc(types.Type.Field, first.len + second.len);
    var i: usize = 0;
    var j: usize = 0;
    for (merged) |*slot| {
        const take_first = j == second.len or
            (i < first.len and types.Type.Field.order(first[i].label, second[j].label) != .gt);
        if (take_first) {
            slot.* = first[i];
            i += 1;
        } else {
            slot.* = second[j];
            j += 1;
        }
    }
    return merged;
}
