test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("tests/basic_tests.zig"));
    refAllDecls(@import("tests/where_tests.zig"));
    refAllDecls(@import("tests/regex_tests.zig"));
    refAllDecls(@import("tests/complex_navigation_tests.zig"));
    refAllDecls(@import("tests/object_literal_tests.zig"));
    refAllDecls(@import("tests/array_literal_tests.zig"));
    refAllDecls(@import("tests/tuple_literal_tests.zig"));
}
