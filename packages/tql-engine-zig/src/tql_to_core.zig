const link = @import("tql_to_core/link.zig");
const lower = @import("tql_to_core/lower.zig");

/// The prelude, linked beneath every query. Compiling it needs a parser, which
/// the desugarer does not import.
pub const prelude_source = @embedFile("tql_to_core/prelude.tql");

/// A written signature, translated to a scheme.
pub const Annotation = lower.Annotation;

/// What a synthesized symbol was generated from.
pub const Synthesis = lower.Synthesis;

pub const SynthesisTable = lower.SynthesisTable;

/// Desugars source files into one linked `Program`.
pub const Desugarer = link.Desugarer;

/// A linked program: the stage's output, and what type checking consumes.
pub const Program = link.Program;

pub const printProgram = link.printProgram;

test {
    const std = @import("std");
    std.testing.refAllDecls(link);
    std.testing.refAllDecls(lower);
    std.testing.refAllDecls(@import("tql_to_core/resolve.zig"));
    std.testing.refAllDecls(@import("tql_to_core/annotation.zig"));
}
