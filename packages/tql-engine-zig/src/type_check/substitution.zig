//! The unification state: what each metavariable has been solved to.

const std = @import("std");
const types = @import("../lang/types.zig");

const Allocator = std.mem.Allocator;

/// The unification state.
pub const Substitution = struct {
    arena: Allocator,
    /// Indexed by `Meta`. `null` means unsolved.
    solutions: std.ArrayList(?types.Type),
    gpa: Allocator,

    pub fn init(gpa: Allocator, arena: Allocator) Substitution {
        return .{ .arena = arena, .solutions = .empty, .gpa = gpa };
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

    /// Binds `id` to `t`. The caller has already run the occurs check.
    pub fn bind(self: *Substitution, id: types.Meta, t: types.Type) void {
        std.debug.assert(self.solutions.items[id] == null);
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

    /// `resolve`, applied through the whole tree. Allocates in the arena when a
    /// child changes; returns `t` itself when nothing did, so a fully-solved
    /// type costs no allocation.
    pub fn resolveDeep(self: *Substitution, t: types.Type) !types.Type {
        const head = self.resolve(t);
        switch (head) {
            .variable, .meta, .primitive => return head,
            .list => |element| {
                const resolved = try self.resolveDeep(element.*);
                if (std.meta.eql(resolved, element.*)) return head;
                return try types.list(self.arena, resolved);
            },
            .record => |fields| {
                var changed = false;
                const copies = try self.arena.alloc(types.Type.Field, fields.len);
                for (fields, copies) |f, *copy| {
                    const resolved = try self.resolveDeep(f.type.*);
                    if (!std.meta.eql(resolved, f.type.*)) changed = true;
                    copy.* = .{ .label = f.label, .type = try types.store(self.arena, resolved) };
                }
                if (!changed) return head;
                return .{ .record = copies };
            },
            .function => |arrow| {
                const from = try self.resolveDeep(arrow.from);
                const to = try self.resolveDeep(arrow.to);
                if (std.meta.eql(from, arrow.from) and std.meta.eql(to, arrow.to)) return head;
                return try types.func(self.arena, from, to);
            },
        }
    }

    /// Whether `id` occurs anywhere in `t`. Binding a metavariable to a type
    /// containing it would build an infinite type, so unification checks this
    /// before every bind.
    pub fn occurs(self: *Substitution, id: types.Meta, t: types.Type) bool {
        const head = self.resolve(t);
        return switch (head) {
            .meta => |other| other == id,
            .variable, .primitive => false,
            .list => |element| self.occurs(id, element.*),
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
            .list => |element| try self.freeMetas(element.*, out),
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
        const metas = try self.arena.alloc(types.Type, scheme.quantified);
        for (metas) |*m| m.* = try self.fresh();
        return .{
            .type = try self.substituteVars(scheme.type, metas),
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
        return self.substituteVars(t, metas);
    }

    /// The inverse of `instantiate`: turns the given free metavariables into
    /// bound `forall` positions, numbered by their order in `metas`.
    pub fn quantify(
        self: *Substitution,
        t: types.Type,
        metas: []const types.Meta,
        constraint_list: []const types.TypeClassConstraint,
    ) !types.Scheme {
        std.debug.assert(metas.len <= std.math.maxInt(types.TypeVar));

        const bound = try self.arena.alloc(types.TypeClassConstraint, constraint_list.len);
        for (constraint_list, bound) |c, *slot| {
            slot.* = .{ .class = c.class, .type = try self.bindMetas(c.type, metas) };
        }

        return .{
            .quantified = @intCast(metas.len),
            .constraints = bound,
            .type = try self.bindMetas(t, metas),
        };
    }

    /// `t` with each metavariable in `metas` replaced by the bound variable at
    /// its index.
    fn bindMetas(self: *Substitution, t: types.Type, metas: []const types.Meta) !types.Type {
        const head = self.resolve(t);
        switch (head) {
            .meta => |id| {
                for (metas, 0..) |m, index| {
                    if (m == id) return .{ .variable = @intCast(index) };
                }
                return head;
            },
            .variable, .primitive => return head,
            .list => |element| return try types.list(self.arena, try self.bindMetas(element.*, metas)),
            .record => |fields| {
                const copies = try self.arena.alloc(types.Type.Field, fields.len);
                for (fields, copies) |f, *copy| {
                    copy.* = .{
                        .label = f.label,
                        .type = try types.store(self.arena, try self.bindMetas(f.type.*, metas)),
                    };
                }
                return .{ .record = copies };
            },
            .function => |arrow| return try types.func(
                self.arena,
                try self.bindMetas(arrow.from, metas),
                try self.bindMetas(arrow.to, metas),
            ),
        }
    }

    /// `t` with each `.variable` replaced by `metas[index]`.
    fn substituteVars(self: *Substitution, t: types.Type, metas: []const types.Type) !types.Type {
        switch (t) {
            .variable => |index| {
                std.debug.assert(index < metas.len);
                return metas[index];
            },
            .meta, .primitive => return t,
            .list => |element| return try types.list(self.arena, try self.substituteVars(element.*, metas)),
            .record => |fields| {
                const copies = try self.arena.alloc(types.Type.Field, fields.len);
                for (fields, copies) |f, *copy| {
                    copy.* = .{
                        .label = f.label,
                        .type = try types.store(self.arena, try self.substituteVars(f.type.*, metas)),
                    };
                }
                return .{ .record = copies };
            },
            .function => |arrow| return try types.func(
                self.arena,
                try self.substituteVars(arrow.from, metas),
                try self.substituteVars(arrow.to, metas),
            ),
        }
    }
};

const TestSubst = struct {
    arena: std.heap.ArenaAllocator,
    subst: Substitution,

    fn init(gpa: Allocator) !*TestSubst {
        const self = try gpa.create(TestSubst);
        self.* = .{ .arena = .init(gpa), .subst = undefined };
        self.subst = Substitution.init(gpa, self.arena.allocator());
        return self;
    }

    fn deinit(self: *TestSubst, gpa: Allocator) void {
        self.subst.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

test "a fresh metavariable is unsolved and distinct" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    try std.testing.expect(!std.meta.eql(a, b));
    try std.testing.expectEqual(null, t.subst.lookup(a.meta));
    try std.testing.expectEqual(2, t.subst.count());
}

test "resolve follows a chain and compresses it" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const c = try t.subst.fresh();
    t.subst.bind(a.meta, b);
    t.subst.bind(b.meta, c);
    t.subst.bind(c.meta, types.int_type);

    try std.testing.expectEqual(types.int_type, t.subst.resolve(a));
    // `a` no longer points at `b`: the chain was collapsed in passing.
    try std.testing.expect(t.subst.lookup(a.meta).?.meta != b.meta);
}

test "resolve stops at an unsolved metavariable" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, b);
    try std.testing.expectEqual(b, t.subst.resolve(a));
}

test "resolve is shallow; resolveDeep rewrites children" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    t.subst.bind(a.meta, types.string_type);
    const listed = try types.list(t.subst.arena, a);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();

    // Shallow: the head is already a constructor, so the element stays `?0`.
    try t.subst.resolve(listed).format(&buf.writer);
    try std.testing.expectEqualStrings("[?0]", buf.written());

    buf.clearRetainingCapacity();
    try (try t.subst.resolveDeep(listed)).format(&buf.writer);
    try std.testing.expectEqualStrings("[String]", buf.written());
}

test "occurs check finds a metavariable nested in a type" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const nested = try types.func(t.subst.arena, types.int_type, try types.list(t.subst.arena, a));

    try std.testing.expect(t.subst.occurs(a.meta, nested));
    try std.testing.expect(!t.subst.occurs(b.meta, nested));
}

test "occurs check sees through a solved metavariable" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(b.meta, try types.list(t.subst.arena, a));

    // `a` is not syntactically in `b`, but it is once `b` is resolved.
    try std.testing.expect(t.subst.occurs(a.meta, b));
}

test "free metavariables are collected once, in first-seen order" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const both = try types.func(t.subst.arena, a, try types.func(t.subst.arena, b, a));

    var found: std.ArrayList(types.Meta) = .empty;
    defer found.deinit(gpa);
    try t.subst.freeMetas(both, &found);

    try std.testing.expectEqualSlices(types.Meta, &.{ a.meta, b.meta }, found.items);
}

test "a solved metavariable is not free" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, types.int_type);
    const both = try types.func(t.subst.arena, a, b);

    var found: std.ArrayList(types.Meta) = .empty;
    defer found.deinit(gpa);
    try t.subst.freeMetas(both, &found);

    try std.testing.expectEqualSlices(types.Meta, &.{b.meta}, found.items);
}

test "instantiation replaces bound variables with fresh metavariables" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    // `identity : Filter a a`, the shape `primitives.zig` writes at comptime.
    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = comptime types.filter_type(types.variable_type(0), types.variable_type(0)),
    };
    const inst = try t.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    try std.testing.expectEqualStrings("?0 -> [?0]", buf.written());
    try std.testing.expectEqual(1, inst.metas.len);
}

test "two instantiations of one scheme share nothing" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = comptime types.filter_type(types.variable_type(0), types.variable_type(0)),
    };
    const first = try t.subst.instantiate(scheme);
    const second = try t.subst.instantiate(scheme);

    t.subst.bind(first.metas[0].meta, types.int_type);
    try std.testing.expectEqual(types.int_type, t.subst.resolve(first.metas[0]));
    try std.testing.expectEqual(second.metas[0], t.subst.resolve(second.metas[0]));
}

test "instantiation leaves the source scheme untouched" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const scheme: types.Scheme = .{
        .quantified = 1,
        .type = comptime types.filter_type(types.variable_type(0), types.variable_type(0)),
    };
    const inst = try t.subst.instantiate(scheme);
    t.subst.bind(inst.metas[0].meta, types.int_type);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> [a]", buf.written());
}

test "resolveDeep rewrites through every constructor" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, types.node_type);
    t.subst.bind(b.meta, types.string_type);

    const fields = try t.arena.allocator().alloc(types.Type.Field, 1);
    fields[0] = .{ .label = "k", .type = try types.store(t.subst.arena, b) };
    const shape = try types.func(t.subst.arena, a, .{ .record = fields });

    const deep = try t.subst.resolveDeep(shape);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try deep.format(&buf.writer);
    try std.testing.expectEqualStrings("Node -> {k: String}", buf.written());
}

test "quantify turns free metavariables into forall positions" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, try types.list(t.subst.arena, a));
    const scheme = try t.subst.quantify(shape, &.{a.meta}, &.{});

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> [a]", buf.written());
    try std.testing.expectEqual(1, scheme.quantified);
}

test "quantify leaves metavariables it was not given free" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, b);
    const scheme = try t.subst.quantify(shape, &.{a.meta}, &.{});

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    // `b` is still owed by an enclosing scope, so it stays a metavariable.
    try std.testing.expectEqualStrings("a -> ?1", buf.written());
}

test "quantify rewrites constraints onto the bound variables" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const shape = try types.func(t.subst.arena, a, types.int_type);
    const scheme = try t.subst.quantify(
        shape,
        &.{a.meta},
        &.{.{ .class = .Sized, .type = a }},
    );

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("Sized a => a -> Int", buf.written());
}

test "quantify then instantiate round-trips" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const scheme = try t.subst.quantify(try types.func(t.subst.arena, a, a), &.{a.meta}, &.{});
    const inst = try t.subst.instantiate(scheme);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try inst.type.format(&buf.writer);
    // A fresh metavariable, not the one that was quantified away.
    try std.testing.expectEqualStrings("?1 -> ?1", buf.written());
}

test "quantify resolves before binding" {
    const gpa = std.testing.allocator;
    const t = try TestSubst.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh();
    const b = try t.subst.fresh();
    t.subst.bind(a.meta, b);

    // `a` resolves to `b`, so quantifying over `b` must catch it through the
    // chain rather than only matching syntactically.
    const scheme = try t.subst.quantify(try types.func(t.subst.arena, a, b), &.{b.meta}, &.{});
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try scheme.format(&buf.writer);
    try std.testing.expectEqualStrings("a -> a", buf.written());
}
