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
        Instruction{ .jmp = .{ .address = 2 } }, // unconditional jump to instruction 2
        Instruction{ .panic = {} }, // landmine
        Instruction{ .halt = {} }, // land here
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "jmp: conditional jump when relation succeeds" {
    const source = "int x;";

    // Strings equal → rel → bool true stored in var 2 (dest=2, state.value stays as node).
    // jmp(addr=5, source=var2, negate=false): jump when true → taken → yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Value{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "hello" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = false } },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "jmp: conditional jump when relation fails" {
    const source = "int x;";

    // Strings differ → rel → bool false stored in var 2.
    // jmp(addr=5, source=var2, negate=true): jump when false → taken → yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Value{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "world" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "jmp: conditional jump not taken when condition not met" {
    const source = "int x;";

    // Strings equal → bool true in var 2.
    // jmp(addr=6, source=var2, negate=true): jump when false → NOT taken (value is true) → fall through to yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Value{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "hello" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 6, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
