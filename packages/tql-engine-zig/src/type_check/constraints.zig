const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");
const classes = core.classes;
const types = core.types;

const Substitution = @import("substitution.zig").Substitution;

/// A constraint together with where it came from.
pub const Constraint = struct {
    class: classes.ClassId,
    type: types.Type,
    origin: diagnostic.Span,
};

pub const Outcome = union(enum) {
    /// Entailment.
    holds,
    /// Refutation.
    fails: types.Type,
    /// Undecidable.
    deferred: types.Meta,
};

/// Decides `class t`.
pub fn entails(subst: *Substitution, class: classes.ClassId, t: types.Type) Outcome {
    var first: ?types.Meta = null;
    const culprit = classes.reduce(subst.classes, subst.datatypes, class, t, subst, FirstResidual{ .first = &first }) catch |e| switch (e) {};
    if (culprit) |c| return .{ .fails = c };
    if (first) |meta| return .{ .deferred = meta };
    return .holds;
}

/// A constraint on a bare metavariable. On a row's metavariable, it holds
/// when it holds of every field the row comes to have.
pub const Residual = struct {
    class: classes.ClassId,
    meta: types.Meta,
};

/// Reduces `class t` to the constraints on bare metavariables it holds under,
/// appending them to `out`. A dictionary class reduces through its instances'
/// contexts, so each residual is in head-normal form.
///
/// Returns the refuted part of `t`, if any.
pub fn reduce(
    subst: *Substitution,
    class: classes.ClassId,
    t: types.Type,
    out: *std.ArrayList(Residual),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!?types.Type {
    return classes.reduce(subst.classes, subst.datatypes, class, t, subst, Collect{ .out = out, .gpa = gpa });
}

/// Keeps the first residual and drops the rest.
const FirstResidual = struct {
    first: *?types.Meta,

    pub const Error = error{};

    pub fn leaf(self: FirstResidual, _: classes.ClassId, t: types.Type) Error!void {
        if (self.first.* == null) self.first.* = metaOf(t);
    }
};

/// Keeps every residual.
const Collect = struct {
    out: *std.ArrayList(Residual),
    gpa: std.mem.Allocator,

    pub const Error = std.mem.Allocator.Error;

    pub fn leaf(self: Collect, class: classes.ClassId, t: types.Type) Error!void {
        try self.out.append(self.gpa, .{ .class = class, .meta = metaOf(t) });
    }
};

fn metaOf(t: types.Type) types.Meta {
    return switch (t) {
        .meta => |id| id,
        else => @panic("a bound type variable reached constraint solving"),
    };
}

/// Constraints raised but not yet decided.
pub const Set = struct {
    items: std.ArrayList(Constraint),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Set {
        return .{ .items = .empty, .gpa = gpa };
    }

    pub fn deinit(self: *Set) void {
        self.items.deinit(self.gpa);
    }

    /// Records `class t`, attributed to `origin`.
    ///
    /// Decided eagerly: a constraint that already fails is reported at its own
    /// span, and one that already holds is dropped rather than stored. Only
    /// genuinely undecided constraints accumulate, which keeps the set small
    /// and means a failure is reported at the earliest point it is knowable.
    pub fn require(
        self: *Set,
        subst: *Substitution,
        class: classes.ClassId,
        t: types.Type,
        origin: diagnostic.Span,
    ) !?Violation {
        switch (entails(subst, class, t)) {
            .holds => return null,
            .fails => |culprit| return .{ .class = class, .type = culprit, .origin = origin },
            .deferred => {
                try self.items.append(self.gpa, .{ .class = class, .type = t, .origin = origin });
                return null;
            },
        }
    }

    /// Re-decides every deferred constraint against the current substitution,
    /// dropping those that now hold and keeping those still undecided.
    ///
    /// Returns the first constraint that has become unsatisfiable, at its
    /// origin span.
    pub fn recheck(self: *Set, subst: *Substitution) !?Violation {
        var kept: std.ArrayList(Constraint) = .empty;
        errdefer kept.deinit(self.gpa);

        for (self.items.items) |c| {
            switch (entails(subst, c.class, c.type)) {
                .holds => {},
                .fails => |culprit| {
                    kept.deinit(self.gpa);
                    return .{ .class = c.class, .type = culprit, .origin = c.origin };
                },
                .deferred => try kept.append(self.gpa, c),
            }
        }

        self.items.deinit(self.gpa);
        self.items = kept;
        return null;
    }

    /// The constraints still undecided, for generalization to quantify over
    /// and for `main` to reject as ambiguous.
    pub fn all(self: *const Set) []const Constraint {
        return self.items.items;
    }

    /// Those undecided constraints mentioning any of `metas`, which are the
    /// ones generalization carries into the scheme. A constraint on a
    /// metavariable that is *not* being quantified stays in the set, still
    /// owed by an enclosing scope.
    pub fn partitionByMetas(
        self: *Set,
        subst: *Substitution,
        metas: []const types.Meta,
        out: *std.ArrayList(Constraint),
        out_gpa: std.mem.Allocator,
    ) !void {
        var kept: std.ArrayList(Constraint) = .empty;
        errdefer kept.deinit(self.gpa);

        for (self.items.items) |c| {
            if (try mentionsAny(subst, c.type, metas, self.gpa)) {
                try out.append(out_gpa, c);
            } else {
                try kept.append(self.gpa, c);
            }
        }

        self.items.deinit(self.gpa);
        self.items = kept;
    }
};

/// A constraint the table refutes, with the term that introduced it.
pub const Violation = struct {
    class: classes.ClassId,
    type: types.Type,
    origin: diagnostic.Span,

    /// Format with the class spelled as `registry` declares it.
    pub fn named(self: Violation, registry: *const classes.Registry) Named {
        return .{ .violation = self, .registry = registry };
    }

    pub const Named = struct {
        violation: Violation,
        registry: *const classes.Registry,

        pub fn format(self: Named, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("`{s} {f}` is not satisfied.", .{
                self.registry.spelling(self.violation.class),
                self.violation.type.operand(),
            });
        }
    };
};

/// Whether `t`, under the current substitution, has any of `metas` free.
pub fn mentionsAny(
    subst: *Substitution,
    t: types.Type,
    metas: []const types.Meta,
    gpa: std.mem.Allocator,
) !bool {
    var free: std.ArrayList(types.Meta) = .empty;
    defer free.deinit(gpa);
    try subst.freeMetas(t, &free);
    for (free.items) |id| {
        for (metas) |m| if (id == m) return true;
    }
    return false;
}
