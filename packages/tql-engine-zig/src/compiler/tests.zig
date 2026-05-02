const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const runtime = @import("../runtime.zig");

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@import("tests/infrastructure.zig"));
    refAllDecls(@import("tests/unified.zig"));
}
