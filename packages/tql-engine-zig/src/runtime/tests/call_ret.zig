const std = @import("std");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ValueSource = types.ValueSource;
const Value = types.Value;

const TestContext = @import("./test_helpers.zig").TestContext;

test "call/ret: basic call and return" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 3      // Call function at address 3
    // 1: yield       // After return, yield the root node
    // 2: halt        // Then halt
    // 3: noop        // Function starts here (just a placeholder)
    // 4: ret         // Return from function
    const instructions = [_]Instruction{
        Instruction{ .call = 3 },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
        Instruction{ .noop = {} },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield the translation_unit once after returning from the call
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "call/ret: yields inside called function" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    // Program:
    // 0: call 4             // Call function at address 4
    // 1: yield              // After return, yield the root node
    // 2: halt               // Then halt
    // 3: panic              // Landmine
    // 4: trv child          // Function: get first child
    // 5: yield              // Yield it
    // 6: ret                // Return
    const instructions = [_]Instruction{
        Instruction{ .call = 4 },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = {} },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield first function_definition, then translation_unit after return
    // (only one child yields before ret unwinds the stack)
    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
        "translation_unit",
    });
}

test "call/ret: nested calls" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 4         // Call outer function at address 4
    // 1: yield          // After outer returns, yield
    // 2: halt           // Then halt
    // 3: panic          // Landmine
    // 4: call 7         // Outer function: call inner function at address 7
    // 5: ret            // Then return from outer
    // 6: panic          // Landmine
    // 7: yield          // Inner function: yield translation_unit
    // 8: ret            // Then return from inner
    const instructions = [_]Instruction{
        Instruction{ .call = 4 },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .call = 7 },
        Instruction{ .ret = {} },
        Instruction{ .panic = {} },
        Instruction{ .yield = {} },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield twice: once from inner function, once after full return
    try ctx.expectMatchKinds(&[_][]const u8{
        "translation_unit",
        "translation_unit",
    });
}

test "call/ret: preserves environment correctly" {
    const source =
        \\ void foo() {}
    ;

    // Program that tests environment preservation:
    // 0: asn 1 "original"  // asn x="original" before call
    // 1: call 5            // Call function
    // 2: asn 2 "after"     // asn y="after" after return
    // 3: yield             // Yield with both x and y
    // 4: halt
    // 5: asn 1 "modified"  // Function: try to modify x
    // 6: asn 3 "local"     // Function: asn z="local"
    // 7: ret               // Return

    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "original" } } } },
        Instruction{ .call = 5 },
        Instruction{ .asn = .{ .variable_id = 2, .source = .{ .literal = Value{ .string = "after" } } } },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "modified" } } } },
        Instruction{ .asn = .{ .variable_id = 3, .source = .{ .literal = Value{ .string = "local" } } } },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    // Should have exactly one match
    var match_count: usize = 0;
    while (try ctx.runtime.nextMatch()) |match| {
        match_count += 1;

        // Verify environment: x should be "original" (not "modified"), y should be "after", z should not exist
        try std.testing.expect(std.mem.eql(u8, match.environment.get(1).?.string, "original"));
        try std.testing.expect(std.mem.eql(u8, match.environment.get(2).?.string, "after"));
        try std.testing.expect(match.environment.get(3) == null); // z was only in function scope
    }

    try std.testing.expectEqual(@as(usize, 1), match_count);
}
