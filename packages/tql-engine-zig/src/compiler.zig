const core = @import("compiler/core.zig");

pub const Program = core.Program;
pub const VariableTable = core.VariableTable;
pub const InstructionBuilder = core.InstructionBuilder;
pub const Compiler = core.Compiler;

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("compiler/tests.zig"));
}
