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
    const head = subst.resolve(t);
    return switch (head) {
        .meta => |id| .{ .deferred = id },
        .variable => unreachable,
        .primitive => |p| if (holdsForPrimitive(class, p)) .holds else .{ .fails = head },
        .constructor => |c| switch (subst.datatypes.get(c.name).classes.forClass(class)) {
            .never => .{ .fails = head },
            // `Sized [a]` is the one that does not descend: a list has a
            // length whatever its elements are.
            .always => .holds,
            .fields => conjunctionOf(subst, class, c.arguments),
        },
        .record => |fields| switch (class) {
            .Sized, .Ord => .{ .fails = head },
            .Eq, .Serial => conjunction(subst, class, fields),
        },
        .function => .{ .fails = head },
    };
}

fn conjunctionOf(
    subst: *Substitution,
    class: types.TypeClassConstraint.Class,
    arguments: []const types.Type,
) Outcome {
    var deferred: ?types.Meta = null;
    for (arguments) |argument| {
        switch (entails(subst, class, argument)) {
            .holds => {},
            .fails => |culprit| return .{ .fails = culprit },
            .deferred => |id| deferred = deferred orelse id,
        }
    }
    if (deferred) |id| return .{ .deferred = id };
    return .holds;
}

fn conjunction(subst: *Substitution, class: types.TypeClassConstraint.Class, fields: []const types.Type.Field) Outcome {
    var deferred: ?types.Meta = null;
    for (fields) |f| {
        switch (entails(subst, class, f.type.*)) {
            .holds => {},
            .fails => |culprit| return .{ .fails = culprit },
            .deferred => |id| deferred = deferred orelse id,
        }
    }
    if (deferred) |id| return .{ .deferred = id };
    return .holds;
}

fn holdsForPrimitive(class: types.TypeClassConstraint.Class, p: types.Primitive) bool {
    return switch (class) {
        .Eq => switch (p) {
            .Int, .String, .Range, .Node => true,
            .Regex => false,
        },
        .Ord => switch (p) {
            .Int, .String => true,
            .Regex, .Node, .Range => false,
        },
        .Sized => switch (p) {
            .String => true,
            .Int, .Regex, .Node, .Range => false,
        },
        .Serial => switch (p) {
            .Int, .String, .Node, .Range => true,
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
        try w.print("`{s} ", .{self.class.spelling()});
        try self.type.format(w);
        try w.writeAll("` is not satisfied.");
    }
};

fn mentionsAny(
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

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    subst: Substitution,
    set: Set,
    interner: core.Interner,
    datatypes: core.datatypes.Registry,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .arena = .init(gpa), .subst = undefined, .interner = try core.Interner.init(gpa), .datatypes = core.datatypes.Registry.init(gpa), .set = Set.init(gpa) };
        try self.datatypes.declareStructural(&self.interner, self.arena.allocator());
        self.subst = Substitution.init(gpa, self.arena.allocator(), &self.datatypes);
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.set.deinit();
        self.subst.deinit();
        self.datatypes.deinit();
        self.interner.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn record(self: *Fixture, labels: []const []const u8, field_types: []const types.Type) !types.Type {
        const fields = try self.arena.allocator().alloc(types.Type.Field, labels.len);
        for (labels, field_types, fields) |label, t, *f| {
            f.* = .{ .label = label, .type = try types.store(self.subst.arena, t) };
        }
        return .{ .record = fields };
    }

    fn expectHolds(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expectEqual(Outcome.holds, entails(&self.subst, class, t));
    }

    fn expectFails(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expect(entails(&self.subst, class, t) == .fails);
    }

    fn expectDeferred(self: *Fixture, class: types.TypeClassConstraint.Class, t: types.Type) !void {
        try testing.expect(entails(&self.subst, class, t) == .deferred);
    }
};

const some_span: diagnostic.Span = .{
    .start_byte = 7,
    .end_byte = 16,
    .start_point = .{ .row = 0, .column = 7 },
    .end_point = .{ .row = 0, .column = 16 },
};

test "Eq holds for the five scalars and not regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    for ([_]types.Type{
        try fix.subst.datatypes.boolType(fix.subst.arena),
        types.int_type,
        types.string_type,
        types.range_type,
        types.node_type,
    }) |t| try fix.expectHolds(.Eq, t);

    try fix.expectFails(.Eq, types.regex_type);
}

test "Ord holds only for int and string" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Ord, types.int_type);
    try fix.expectHolds(.Ord, types.string_type);

    try fix.expectFails(.Ord, types.node_type);
    try fix.expectHolds(.Eq, types.node_type);

    try fix.expectFails(.Ord, try fix.subst.datatypes.boolType(fix.subst.arena));
    try fix.expectFails(.Ord, types.range_type);
    try fix.expectFails(.Ord, types.regex_type);
}

test "Sized holds for string and lists, not for int" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Sized, types.string_type);
    try fix.expectHolds(.Sized, try fix.subst.datatypes.list(fix.subst.arena, types.node_type));
    try fix.expectFails(.Sized, types.int_type);
}

test "Sized on a list does not descend" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // A list of functions still has a length, even though the element type
    // has no constraint at all.
    const of_functions = try fix.subst.datatypes.list(
        fix.subst.arena,
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try fix.expectHolds(.Sized, of_functions);
    try fix.expectFails(.Serial, of_functions);
}

test "Sized on a list of an unsolved metavariable holds without deferring" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectHolds(.Sized, try fix.subst.datatypes.list(fix.subst.arena, a));
}

test "Serial holds for the five scalars and not regex" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    for ([_]types.Type{
        try fix.subst.datatypes.boolType(fix.subst.arena),
        types.int_type,
        types.string_type,
        types.node_type,
        types.range_type,
    }) |t| try fix.expectHolds(.Serial, t);

    try fix.expectFails(.Serial, types.regex_type);
}

test "structural classes descend into lists" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Eq, try fix.subst.datatypes.list(fix.subst.arena, types.int_type));
    try fix.expectFails(.Eq, try fix.subst.datatypes.list(fix.subst.arena, types.regex_type));
    try fix.expectHolds(.Serial, try fix.subst.datatypes.list(fix.subst.arena, try fix.subst.datatypes.list(fix.subst.arena, types.node_type)));
}

test "structural classes descend into records" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    try fix.expectHolds(.Serial, try fix.record(
        &.{ "k", "n" },
        &.{ types.string_type, types.int_type },
    ));
    try fix.expectFails(.Serial, try fix.record(
        &.{ "k", "bad" },
        &.{ types.string_type, types.regex_type },
    ));
}

test "Ord and Sized do not hold for records" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const r = try fix.record(&.{"n"}, &.{types.int_type});
    try fix.expectFails(.Ord, r);
    try fix.expectFails(.Sized, r);
}

test "Ord does not hold for a list even of ordered elements" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // `Ord` is exactly `Int` and `String`; nothing structural joins it.
    try fix.expectFails(.Ord, try fix.subst.datatypes.list(fix.subst.arena, types.int_type));
}

test "a function fails every class, and a filter is a function" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const projection = try types.func(fix.subst.arena, types.node_type, types.string_type);
    const filter = try fix.subst.datatypes.filter(fix.subst.arena, types.node_type, types.string_type);

    for ([_]types.TypeClassConstraint.Class{ .Eq, .Ord, .Serial, .Sized }) |class| {
        try fix.expectFails(class, projection);
        try fix.expectFails(class, filter);
    }
}

test "a container holding a function is outside Eq and Serial" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    // What `errors/types/017` and `errors/output/006` assert: the element
    // type is `Node -> String`.
    const of_projections = try fix.subst.datatypes.list(
        fix.subst.arena,
        try types.func(fix.subst.arena, types.node_type, types.string_type),
    );
    try fix.expectFails(.Eq, of_projections);
    try fix.expectFails(.Serial, of_projections);
}

test "the reported culprit is the element, not the container" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const nested = try fix.subst.datatypes.list(fix.subst.arena, try fix.subst.datatypes.list(fix.subst.arena, types.regex_type));
    const outcome = entails(&fix.subst, .Serial, nested);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try outcome.fails.format(&buf.writer);
    try testing.expectEqualStrings("Regex", buf.written());
}

test "an unsolved metavariable defers" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectDeferred(.Serial, a);
    try fix.expectDeferred(.Eq, try fix.subst.datatypes.list(fix.subst.arena, a));
}

test "deferral resolves once the metavariable is solved" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try fix.expectDeferred(.Ord, a);

    fix.subst.bind(a.meta, types.int_type);
    try fix.expectHolds(.Ord, a);
}

test "a failing field beats a deferring one" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    // No solution for `a` can rescue the `regex`, so the answer is failure
    // rather than deferral.
    const mixed = try fix.record(&.{ "open", "bad" }, &.{ a, types.regex_type });
    try fix.expectFails(.Serial, mixed);
}

test "a deferring field defers the whole when the rest hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const mixed = try fix.record(&.{ "n", "open" }, &.{ types.int_type, a });
    try fix.expectDeferred(.Serial, mixed);
}

test "require decides eagerly and stores only the undecided" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();

    try testing.expectEqual(
        null,
        try fix.set.require(&fix.subst, .Eq, types.int_type, some_span),
    );
    try testing.expectEqual(0, fix.set.all().len);

    try testing.expectEqual(
        null,
        try fix.set.require(&fix.subst, .Serial, a, some_span),
    );
    try testing.expectEqual(1, fix.set.all().len);
}

test "require reports a violation at the origin span" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const v = (try fix.set.require(&fix.subst, .Eq, types.regex_type, some_span)).?;
    try testing.expectEqual(some_span.start_byte, v.origin.start_byte);
    try testing.expectEqual(some_span.end_byte, v.origin.end_byte);
    try testing.expectEqual(0, fix.set.all().len);
}

test "a violation renders as the fixture writes it" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const v = (try fix.set.require(&fix.subst, .Eq, types.regex_type, some_span)).?;

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try v.format(&buf.writer);
    // `errors/types/015` asserts exactly this sentence.
    try testing.expectEqualStrings("`Eq Regex` is not satisfied.", buf.written());
}

test "recheck drops constraints that have come to hold" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.set.require(&fix.subst, .Serial, a, some_span);
    try testing.expectEqual(1, fix.set.all().len);

    fix.subst.bind(a.meta, types.node_type);
    try testing.expectEqual(null, try fix.set.recheck(&fix.subst));
    try testing.expectEqual(0, fix.set.all().len);
}

test "recheck reports a constraint that has become unsatisfiable" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.set.require(&fix.subst, .Ord, a, some_span);

    fix.subst.bind(a.meta, types.node_type);
    const v = (try fix.set.recheck(&fix.subst)).?;
    try testing.expectEqual(types.TypeClassConstraint.Class.Ord, v.class);
    // Still attributed to the term that raised it, not to where it was found.
    try testing.expectEqual(some_span.start_byte, v.origin.start_byte);
}

test "recheck keeps a constraint that is still undecided" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    _ = try fix.set.require(&fix.subst, .Serial, a, some_span);

    fix.subst.bind(a.meta, try fix.subst.datatypes.list(fix.subst.arena, b));
    try testing.expectEqual(null, try fix.set.recheck(&fix.subst));
    try testing.expectEqual(1, fix.set.all().len);
}

test "generalization takes the constraints on the quantified metavariables" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    const b = try fix.subst.fresh();
    _ = try fix.set.require(&fix.subst, .Sized, a, some_span);
    _ = try fix.set.require(&fix.subst, .Serial, b, some_span);

    var taken: std.ArrayList(Constraint) = .empty;
    defer taken.deinit(gpa);
    try fix.set.partitionByMetas(&fix.subst, &.{a.meta}, &taken, gpa);

    // `a`'s constraint goes into the scheme; `b`'s is still owed by the
    // enclosing scope.
    try testing.expectEqual(1, taken.items.len);
    try testing.expectEqual(types.TypeClassConstraint.Class.Sized, taken.items[0].class);
    try testing.expectEqual(1, fix.set.all().len);
    try testing.expectEqual(types.TypeClassConstraint.Class.Serial, fix.set.all()[0].class);
}

test "a constraint on a type mentioning a quantified metavariable is taken" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    _ = try fix.set.require(&fix.subst, .Serial, try fix.subst.datatypes.list(fix.subst.arena, a), some_span);

    var taken: std.ArrayList(Constraint) = .empty;
    defer taken.deinit(gpa);
    try fix.set.partitionByMetas(&fix.subst, &.{a.meta}, &taken, gpa);

    try testing.expectEqual(1, taken.items.len);
    try testing.expectEqual(0, fix.set.all().len);
}

test "the length primitive's Sized constraint defers on an open input" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const a = try fix.subst.fresh();
    try testing.expectEqual(
        null,
        try fix.set.require(&fix.subst, .Sized, a, some_span),
    );

    fix.subst.bind(a.meta, types.string_type);
    try testing.expectEqual(null, try fix.set.recheck(&fix.subst));
}
