// Main test file that imports all test modules
// Tests are organized by instruction type in the tests/ subdirectory

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("tests/basic.zig"));
    refAllDecls(@import("tests/trv.zig"));
    refAllDecls(@import("tests/asn.zig"));
    refAllDecls(@import("tests/rel.zig"));
    refAllDecls(@import("tests/jmp.zig"));
    refAllDecls(@import("tests/call_ret.zig"));
    refAllDecls(@import("tests/probe.zig"));
}
