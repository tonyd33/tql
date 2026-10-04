const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const core = @import("../core.zig");
const datatypes = core.datatypes;
const types = core.types;

const Substitution = @import("substitution.zig").Substitution;

/// A constraint together with where it came from.
pub const Constraint = struct {
    class: types.TypeClassConstraint.Class,
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
pub fn entails(subst: *Substitution, class: types.TypeClassConstraint.Class, t: types.Type) Outcome {
    var first: ?types.Meta = null;
    const culprit = walk(FirstResidual, .{ .first = &first }, subst, class, t) catch |e| switch (e) {};
    if (culprit) |c| return .{ .fails = c };
    if (first) |meta| return .{ .deferred = meta };
    return .holds;
}

/// A constraint on a bare metavariable. On a row's metavariable, it holds
/// when it holds of every field the row comes to have.
pub const Residual = struct {
    class: types.TypeClassConstraint.Class,
    meta: types.Meta,
};

/// Reduces `class t` to the constraints on bare metavariables it holds under,
/// appending them to `out`.
///
/// Returns the refuted part of `t`, if any.
pub fn reduce(
    subst: *Substitution,
    class: types.TypeClassConstraint.Class,
    t: types.Type,
    out: *std.ArrayList(Residual),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!?types.Type {
    return walk(Collect, .{ .out = out, .gpa = gpa }, subst, class, t);
}

/// Keeps the first residual and drops the rest.
const FirstResidual = struct {
    first: *?types.Meta,

    const Error = error{};

    fn residual(self: FirstResidual, r: Residual) Error!void {
        if (self.first.* == null) self.first.* = r.meta;
    }
};

/// Keeps every residual.
const Collect = struct {
    out: *std.ArrayList(Residual),
    gpa: std.mem.Allocator,

    const Error = std.mem.Allocator.Error;

    fn residual(self: Collect, r: Residual) Error!void {
        try self.out.append(self.gpa, r);
    }
};

/// Reduces `class t`, handing each residual to `sink` in the order it is
/// reached.
///
/// Returns the first refuted part of `t`, if any, written as `t` writes it,
/// alias included.
fn walk(
    comptime Sink: type,
    sink: Sink,
    subst: *Substitution,
    class: types.TypeClassConstraint.Class,
    t: types.Type,
) Sink.Error!?types.Type {
    const written = subst.resolve(t);
    switch (subst.expand(written)) {
        .meta => |id| try sink.residual(.{ .class = class, .meta = id }),
        .variable => @panic("a bound type variable reached constraint solving"),
        .alias => unreachable,
        .primitive => |p| if (!holdsForPrimitive(class, p)) return written,
        .constructor => |c| switch (subst.datatypes.get(c.name).classes.forClass(class)) {
            .never => return written,
            // `Sized [a]` is the one that does not descend: a list has a
            // length whatever its elements are.
            .always => {},
            .fields => for (c.arguments) |argument| {
                if (try walk(Sink, sink, subst, class, argument)) |culprit| return culprit;
            },
        },
        .record => |r| switch (class) {
            .Sized, .Ord => return written,
            // A row holds when every field it comes to have does.
            .Eq, .Serial => {
                for (r.fields) |f| {
                    if (try walk(Sink, sink, subst, class, f.type.*)) |culprit| return culprit;
                }
                if (r.rest) |rest| return try walk(Sink, sink, subst, class, rest.*);
            },
        },
        .function => return written,
    }
    return null;
}

fn holdsForPrimitive(class: types.TypeClassConstraint.Class, p: types.Primitive) bool {
    return switch (class) {
        .Eq => switch (p) {
            .Int, .String, .Node, .Kind => true,
            .Regex => false,
        },
        .Ord => switch (p) {
            .Int, .String => true,
            .Regex, .Node, .Kind => false,
        },
        .Sized => switch (p) {
            .String => true,
            .Int, .Regex, .Node, .Kind => false,
        },
        .Serial => switch (p) {
            .Int, .String, .Node, .Kind => true,
            .Regex => false,
        },
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
        class: types.TypeClassConstraint.Class,
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
    class: types.TypeClassConstraint.Class,
    type: types.Type,
    origin: diagnostic.Span,

    pub fn format(self: Violation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("`{s} {f}` is not satisfied.", .{ self.class.spelling(), self.type.operand() });
    }
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
