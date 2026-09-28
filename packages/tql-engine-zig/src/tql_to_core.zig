//! Module for converting surface TQL syntax to Core, a lower-level
//! lambda-style language.

const link = @import("tql_to_core/link.zig");
const desugar = @import("tql_to_core/desugar.zig");

/// Desugars source files into one linked `core.Program`.
pub const Desugarer = link.Desugarer;

test {
    const std = @import("std");
    std.testing.refAllDecls(link);
    std.testing.refAllDecls(desugar);
    std.testing.refAllDecls(@import("tql_to_core/resolve.zig"));
    std.testing.refAllDecls(@import("tql_to_core/annotation.zig"));
}
