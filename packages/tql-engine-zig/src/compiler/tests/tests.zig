test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("basic_tests.zig"));
    refAllDecls(@import("where_tests.zig"));
    refAllDecls(@import("regex_tests.zig"));
    refAllDecls(@import("complex_navigation_tests.zig"));
    refAllDecls(@import("object_literal_tests.zig"));
}
