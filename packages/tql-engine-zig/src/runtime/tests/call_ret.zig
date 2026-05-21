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
        Instruction{ .yield = .{} },
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
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
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
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .call = 7 },
        Instruction{ .ret = {} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
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

    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "original" } } } },
        Instruction{ .call = 7 },
        Instruction{ .asn = .{ .variable_id = 2, .source = .{ .literal = Value{ .string = "after" } } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 2 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 3 } } },
        Instruction{ .halt = .{} },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Value{ .string = "modified" } } } },
        Instruction{ .asn = .{ .variable_id = 3, .source = .{ .literal = Value{ .string = "local" } } } },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    // Should have exactly one match
    var value = try ctx.runtime.next();
    try std.testing.expectEqualStrings(value.?.string, "original");

    value = try ctx.runtime.next();
    try std.testing.expectEqualStrings(value.?.string, "after");

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value.?.nothing, {});

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value, null);
}
