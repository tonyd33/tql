//! Type checking: Hindley-Milner inference over linked Core.

const constraints = @import("type_check/constraints.zig");
const erase = @import("type_check/erase.zig");
const infer = @import("type_check/infer.zig");
const substitution = @import("type_check/substitution.zig");
const unify = @import("type_check/unify.zig");

/// Why two types could not be made equal. Public because a diagnostic renders
/// it; the unifier itself is not.
pub const Mismatch = unify.Mismatch;

/// A constraint no instance satisfies, with the term that introduced it.
/// Public for the same reason: a diagnostic renders it.
pub const Violation = constraints.Violation;

/// Type-checks a linked program, writing each definition's scheme into its
/// environment and reporting through a `diagnostic.Sink`, then erases every
/// `newtype`.
pub fn check(gpa: std.mem.Allocator, program: *core.Program, sink: *diagnostic.Sink) !void {
    try infer.check(gpa, program, sink);
    try erase.program(program);
}

pub const Error = infer.Error;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(constraints);
    refAllDecls(erase);
    refAllDecls(infer);
    refAllDecls(substitution);
    refAllDecls(unify);
}

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");
const primitives = @import("primitives.zig");
const test_support = core.test_support;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Substitution = substitution.Substitution;

/// A substitution over one environment.
const Fixture = struct {
    pb: test_support.ProgramBuilder,
    subst: Substitution,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .pb = try test_support.ProgramBuilder.init(gpa),
            .subst = undefined,
        };
        self.subst = Substitution.init(gpa, self.pb.env.allocator(), &self.pb.env.datatypes, &self.pb.env.classes);
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.subst.deinit();
        self.pb.deinit();
        gpa.destroy(self);
    }
};

test "occurs check sees through a solved metavariable" {
    const gpa = std.testing.allocator;
    const t = try Fixture.init(gpa);
    defer t.deinit(gpa);

    const a = try t.subst.fresh(.type);
    const b = try t.subst.fresh(.type);
    t.subst.bind(b.meta, try t.subst.datatypes.list(t.subst.arena, a));

    // `a` is not syntactically in `b`, but it is once `b` is resolved.
    try std.testing.expect(t.subst.occurs(a.meta, b));
}

test "a record scheme at the field ceiling still builds" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const labels = try gpa.alloc([]const u8, primitives.max_record_fields);
    defer gpa.free(labels);
    for (labels) |*l| l.* = "f";

    const scheme = try primitives.synthesizedScheme(fix.pb.env.allocator(), &fix.pb.env.datatypes, .{ .record = labels });
    try testing.expectEqual(primitives.max_record_fields, scheme.variables.len);
}
