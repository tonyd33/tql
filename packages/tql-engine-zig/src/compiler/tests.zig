const std = @import("std");

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@import("tests/tests.zig"));
}
