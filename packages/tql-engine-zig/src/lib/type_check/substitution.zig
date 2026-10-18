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

    fn replace(self: Leaf, head: types.Type) types.Type {
        switch (self) {
            .resolved => {},
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
    /// Expands every alias whose arguments mention this metavariable.
    unalias: ?types.Meta,

    pub fn head(self: Rewriter, t: types.Type) types.Type {
        var current = self.subst.resolve(t);
        const id = self.unalias orelse return current;
        while (current == .alias and self.subst.occurs(id, current)) {
            current = self.subst.resolve(current.alias.expansion);
        }
        return current;
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
    /// Indexed by `Meta`.
    ///
    /// Invariants:
    /// - No solution reaches its own metavariable, alias arguments included.
    metas: std.MultiArrayList(Entry),
    gpa: Allocator,

    const Entry = struct {
        /// `null` means unsolved.
        solution: ?types.Type,
        kind: types.Kind,
        /// Whether the metavariable stands in a type an error was reported
        /// on.
        poisoned: bool,
    };

    pub fn init(
        gpa: Allocator,
        arena: Allocator,
        declared: *const datatypes.Registry,
        registry: *const classes.Registry,
    ) Substitution {
        return .{ .arena = arena, .datatypes = declared, .classes = registry, .metas = .empty, .gpa = gpa };
    }

    pub fn deinit(self: *Substitution) void {
        self.metas.deinit(self.gpa);
    }

    /// A metavariable of kind `kind` no type mentions yet.
    pub fn fresh(self: *Substitution, kind: types.Kind) !types.Type {
        const id: types.Meta = @intCast(self.metas.len);
        try self.metas.append(self.gpa, .{ .solution = null, .kind = kind, .poisoned = false });
        return .{ .meta = id };
    }

    pub fn kindOf(self: *const Substitution, id: types.Meta) types.Kind {
        return self.metas.items(.kind)[id];
    }

    pub fn count(self: *const Substitution) usize {
        return self.metas.len;
    }

    /// What `id` is solved to, or null if it is still unknown.
    pub fn lookup(self: *const Substitution, id: types.Meta) ?types.Type {
        return self.metas.items(.solution)[id];
    }

    /// Binds `id` to `t`, poisoning `t` when `id` is poisoned.
    ///
    /// Preconditions:
    /// - `id` is unsolved.
    /// - `id` does not occur in `t`, alias arguments included.
    pub fn bind(self: *Substitution, id: types.Meta, t: types.Type) void {
        self.metas.items(.solution)[id] = t;
        if (self.metas.items(.poisoned)[id]) self.poison(t);
    }

    /// Poisons every metavariable of `t`, solved ones included.
    pub fn poison(self: *Substitution, t: types.Type) void {
        switch (t) {
            .meta => |id| {
                self.metas.items(.poisoned)[id] = true;
                if (self.metas.items(.solution)[id]) |solution| self.poison(solution);
            },
            .variable => {},
            .constructor => |c| for (c.arguments) |argument| self.poison(argument),
            .record => |r| {
                for (r.fields) |f| self.poison(f.type.*);
                if (r.rest) |rest| self.poison(rest.*);
            },
            .function => |arrow| {
                self.poison(arrow.from);
                self.poison(arrow.to);
            },
            .application => |a| {
                self.poison(a.head);
                self.poison(a.argument);
            },
            .alias => |a| {
                for (a.arguments) |argument| self.poison(argument);
                self.poison(a.expansion);
            },
        }
    }

    /// Whether `t` reaches a poisoned metavariable, through solutions
    /// included.
    pub fn isPoisoned(self: *const Substitution, t: types.Type) bool {
        return switch (t) {
            .meta => |id| self.metas.items(.poisoned)[id] or
                if (self.metas.items(.solution)[id]) |solution| self.isPoisoned(solution) else false,
            .variable => false,
            .constructor => |c| for (c.arguments) |argument| {
                if (self.isPoisoned(argument)) break true;
            } else false,
            .record => |r| for (r.fields) |f| {
                if (self.isPoisoned(f.type.*)) break true;
            } else if (r.rest) |rest| self.isPoisoned(rest.*) else false,
            .function => |arrow| self.isPoisoned(arrow.from) or self.isPoisoned(arrow.to),
            .application => |a| self.isPoisoned(a.head) or self.isPoisoned(a.argument),
            .alias => |a| for (a.arguments) |argument| {
                if (self.isPoisoned(argument)) break true;
            } else self.isPoisoned(a.expansion),
        };
    }

    /// Follows metavariable solutions until reaching an unsolved metavariable
    /// or a constructor. Shallow: the result's *children* may still be solved
    /// metavariables.
    pub fn resolve(self: *Substitution, t: types.Type) types.Type {
        var current = t;
        while (current == .meta) {
            const solution = self.metas.items(.solution)[current.meta] orelse return current;
            // Path compression: point the head straight at what it resolves
            // to, keeping the poison of the metavariable skipped.
            if (solution == .meta) {
                if (self.metas.items(.solution)[solution.meta]) |next| {
                    self.metas.items(.solution)[current.meta] = next;
                    if (self.metas.items(.poisoned)[solution.meta]) self.metas.items(.poisoned)[current.meta] = true;
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
    /// head's solution at its argument, and following a record's row to the
    /// end. An `.application` in the result has an unsolved head.
    pub fn normalize(self: *Substitution, t: types.Type) Allocator.Error!types.Type {
        const head = self.expand(t);
        if (head == .record) return .{ .record = try self.flatten(head.record) };
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
        return self.rewrite(t, .resolved, null);
    }

    /// `t` with each metavariable and bound variable replaced by
    /// `leaf.replace` of it, resolving every node first, and expanding every
    /// alias whose arguments mention `unalias`.
    ///
    /// Allocates in the arena only along a path where a node changed, and
    /// returns `t` itself when none did.
    fn rewrite(self: *Substitution, t: types.Type, leaf: Leaf, unalias: ?types.Meta) Allocator.Error!types.Type {
        return try types.rewrite(self.arena, t, Rewriter{ .subst = self, .leaf = leaf, .unalias = unalias });
    }

    /// Whether `id` occurs in `t`, alias arguments included.
    pub fn occurs(self: *Substitution, id: types.Meta, t: types.Type) bool {
        const head = self.resolve(t);
        return switch (head) {
            .meta => |other| other == id,
            .variable => false,
            .alias => |a| for (a.arguments) |argument| {
                if (self.occurs(id, argument)) break true;
            } else false,
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

    /// `t` with every alias whose arguments mention `id` replaced by its
    /// expansion, or null when `id` occurs in `t` even so. Binding a
    /// metavariable to a type containing it would build an infinite type, so
    /// unification checks this before every bind.
    pub fn occursCheck(self: *Substitution, id: types.Meta, t: types.Type) Allocator.Error!?types.Type {
        if (!self.occurs(id, t)) return t;
        const expanded = try self.rewrite(t, .resolved, id);
        return if (self.occurs(id, expanded)) null else expanded;
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
        return try self.rewrite(t, .{ .bound = metas }, null);
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
            slot.* = .{ .class = c.class, .type = try self.rewrite(c.type, .{ .bound = metas }, null) };
        }

        const variables = try self.arena.alloc(types.Kind, metas.len);
        for (metas, variables) |id, *kind| kind.* = self.kindOf(id);
        return .{
            .variables = variables,
            .constraints = bound,
            .type = try self.rewrite(t, .{ .bound = metas }, null),
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
