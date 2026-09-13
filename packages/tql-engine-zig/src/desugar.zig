const link = @import("desugar/link.zig");
const lower = @import("desugar/lower.zig");

/// The prelude, linked beneath every query. Compiling it needs a parser, which
/// the desugarer does not import.
pub const prelude_source = @embedFile("desugar/prelude.tql");

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
    std.testing.refAllDecls(@import("desugar/resolve.zig"));
    std.testing.refAllDecls(@import("desugar/annotation.zig"));
}
