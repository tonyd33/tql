//! Type checking: Hindley-Milner inference over linked Core.

const constraints = @import("type_check/constraints.zig");
const infer = @import("type_check/infer.zig");
const schemes = @import("type_check/schemes.zig");
const substitution = @import("type_check/substitution.zig");
const unify = @import("type_check/unify.zig");

/// Why two types could not be made equal. Public because a diagnostic renders
/// it; the unifier itself is not.
pub const Mismatch = unify.Mismatch;

/// A constraint the closed table refutes, with the term that introduced it.
/// Public for the same reason: a diagnostic renders it.
pub const Violation = constraints.Violation;

/// Type-checks a linked program, reporting through a `diagnostic.Sink`.
pub const check = infer.check;

/// A checked program: the schemes of its definitions, and the arena they live
/// in.
pub const Checked = infer.Checked;

pub const Error = infer.Error;

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(constraints);
    refAllDecls(infer);
    refAllDecls(schemes);
    refAllDecls(substitution);
    refAllDecls(unify);
}
