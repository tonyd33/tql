const std = @import("std");
const expectError = std.testing.expectError;

const types = @import("../types.zig");
const Instruction = types.Instruction;

const TestContext = @import("./test_helpers.zig").TestContext;

test "noop: basic" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .noop = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "error: no halt" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .noop = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try expectError(error.ExecuteOutOfBounds, ctx.collectMatches());
}

test "yield: basic" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
