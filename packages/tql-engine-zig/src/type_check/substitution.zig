//! The unification state: what each metavariable has been solved to.

const std = @import("std");
const core = @import("../core.zig");
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

    /// `resolve`, also stripping every alias at the head. The result is
    /// never `.alias`.
    pub fn expand(self: *Substitution, t: types.Type) types.Type {
        var current = self.resolve(t);
        while (current == .alias) current = self.resolve(current.alias.expansion);
        return current;
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
        const head = self.resolve(t);
        switch (head) {
            .variable, .meta => return leaf.replace(head),
            .primitive => return head,
            .constructor => |c| {
                const changed = try self.rewriteAll(c.arguments, leaf) orelse return head;
                return try types.constructed(self.arena, c.name, c.spelling, changed);
            },
            .record => |written| {
                const r = try self.flatten(written);
                var copies: ?[]types.Type.Field = null;
                for (r.fields, 0..) |f, i| {
                    const rewritten = try self.rewrite(f.type.*, leaf);
                    if (copies) |slots| {
                        slots[i] = .{ .label = f.label, .type = try types.store(self.arena, rewritten) };
                    } else if (!std.meta.eql(rewritten, f.type.*)) {
                        const slots = try self.arena.alloc(types.Type.Field, r.fields.len);
                        @memcpy(slots[0..i], r.fields[0..i]);
                        slots[i] = .{ .label = f.label, .type = try types.store(self.arena, rewritten) };
                        copies = slots;
                    }
                }
                var rest = r.rest;
                if (r.rest) |row| {
                    const rewritten = try self.rewrite(row.*, leaf);
                    if (!std.meta.eql(rewritten, row.*)) rest = try types.store(self.arena, rewritten);
                }
                const result: types.Type.Record = .{ .fields = copies orelse r.fields, .rest = rest };
                if (std.meta.eql(result, written)) return head;
                return .{ .record = result };
            },
            .function => |arrow| {
                const from = try self.rewrite(arrow.from, leaf);
                const to = try self.rewrite(arrow.to, leaf);
                if (std.meta.eql(from, arrow.from) and std.meta.eql(to, arrow.to)) return head;
                return try types.func(self.arena, from, to);
            },
            .alias => |a| {
                const changed = try self.rewriteAll(a.arguments, leaf);
                const expansion = try self.rewrite(a.expansion, leaf);
                if (changed == null and std.meta.eql(expansion, a.expansion)) return head;
                return try types.aliased(self.arena, a.spelling, changed orelse a.arguments, expansion);
            },
        }
    }

    /// `rewrite` over each of `ts`, or null when none changed. Allocates from
    /// the first change on, seeded with the unchanged ones before it.
    fn rewriteAll(self: *Substitution, ts: []const types.Type, leaf: Leaf) Allocator.Error!?[]types.Type {
        var copies: ?[]types.Type = null;
        for (ts, 0..) |each, i| {
            const rewritten = try self.rewrite(each, leaf);
            if (copies) |slots| {
                slots[i] = rewritten;
            } else if (!std.meta.eql(rewritten, each)) {
                const slots = try self.arena.alloc(types.Type, ts.len);
                @memcpy(slots[0..i], ts[0..i]);
                slots[i] = rewritten;
                copies = slots;
            }
        }
        return copies;
    }

    /// Whether `id` occurs anywhere in `t`. Binding a metavariable to a type
    /// containing it would build an infinite type, so unification checks this
    /// before every bind.
    pub fn occurs(self: *Substitution, id: types.Meta, t: types.Type) bool {
        const head = self.expand(t);
        return switch (head) {
            .meta => |other| other == id,
            .variable, .primitive => false,
            .alias => unreachable,
            .constructor => |c| for (c.arguments) |argument| {
                if (self.occurs(id, argument)) break true;
            } else false,
            .record => |r| for (r.fields) |f| {
                if (self.occurs(id, f.type.*)) break true;
            } else if (r.rest) |rest| self.occurs(id, rest.*) else false,
            .function => |arrow| self.occurs(id, arrow.from) or self.occurs(id, arrow.to),
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
            .variable, .primitive => {},
            .constructor => |c| for (c.arguments) |argument| try self.freeMetas(argument, out),
            .record => |r| {
                for (r.fields) |f| try self.freeMetas(f.type.*, out);
                if (r.rest) |rest| try self.freeMetas(rest.*, out);
            },
            .function => |arrow| {
                try self.freeMetas(arrow.from, out);
                try self.freeMetas(arrow.to, out);
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
        return types.substitute(self.arena, t, metas);
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

        return .{
            .quantified = @intCast(metas.len),
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
