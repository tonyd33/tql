const std = @import("std");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Value = types.Value;
const Relation = types.Relation;

const TestContext = @import("./test_helpers.zig").TestContext;

test "jmp: basic forward jump" {
    const source =
        \\ void foo() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .jmp = .{ .address = 2 } }, // Jump to instruction 2
        Instruction{ .panic = {} }, // Landmine
        Instruction{ .halt = .{} }, // Land here
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "jmp: conditional jump when relation succeeds" {
    const source = "int x;";

    // Test jumping when flag is true (relation succeeded)
    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.equals,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        // Jump to yield if flag is true (relation succeeded)
        Instruction{ .jmp = .{ .address = 5, .mode = .relates } },
        // Should not reach here
        Instruction{ .panic = {} },
        // Should land here
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "jmp: conditional jump when relation fails" {
    const source = "int x;";

    // Test jumping when flag is false (relation failed)
    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .string = "world" } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.equals,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        // Jump to yield if flag is false (relation failed)
        Instruction{ .jmp = .{ .address = 5, .mode = .not_relates } },
        // Should not reach here
        Instruction{ .panic = {} },
        // Should land here
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "jmp: conditional jump not taken when condition not met" {
    const source = "int x;";

    // Test that jump is skipped when condition is not met
    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.equals,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        // Try to jump if flag is false (but it's true, so skip)
        Instruction{ .jmp = .{ .address = 6, .mode = .not_relates } },
        // Should continue here
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
        // Should not reach here
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
