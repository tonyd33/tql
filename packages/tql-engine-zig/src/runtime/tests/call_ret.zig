const std = @import("std");

const types = @import("../types.zig");
const Value = types.Value;

const ir = @import("../../ir.zig");
const Instruction = ir.Instruction;
const Axis = ir.Axis;
const ValueSource = ir.ValueSource;
const Literal = ir.Literal;

const TestContext = @import("./test_helpers.zig").TestContext;

test "call/ret: basic call and return" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 3      // Call function at address 3
    // 1: yield       // Caller continuation: yield the value the call produced
    // 2: halt        // Then halt
    // 3: noop        // Function starts here (just a placeholder)
    // 4: yield       // "return" is just a yield: this is the call's value
    // 5: halt        // Function falls off the end (call exhausted)
    const instructions = [_]Instruction{
        Instruction{ .call = 3 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .noop = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield the translation_unit once after the call produces its
    // (only) value
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "call/ret: yields inside called function" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 4             // Call function at address 4
    // 1: yield              // Caller continuation: yield the call's value
    // 2: halt               // Then halt
    // 3: panic              // Landmine
    // 4: trv child          // Function: get first child
    // 5: yield              // Yield it: this is the call's value
    // 6: halt               // Function falls off the end (call exhausted)
    const instructions = [_]Instruction{
        Instruction{ .call = 4 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // The callee's yield is consumed as the call's return value; only the
    // caller's continuation (re-)yields it upward. One call, one child, one
    // match.
    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
    });
}

test "call/ret: multi-valued call resumes caller once per callee yield" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    // Program:
    // 0: call 4             // Call function at address 4
    // 1: yield              // Caller continuation: yield the call's value
    // 2: halt               // Then halt
    // 3: panic              // Landmine
    // 4: trv child          // Function: iterate over both children
    // 5: yield              // Yield each one: each is a separate call value
    // 6: halt               // Function exhausted once trv is exhausted
    const instructions = [_]Instruction{
        Instruction{ .call = 4 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // The callee yields once per child; each yield resumes the caller's
    // continuation independently (backtracking), producing one match per
    // callee value.
    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
        "function_definition",
    });
}

test "call/ret: nested calls" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 4         // Call outer function at address 4
    // 1: yield          // After outer call produces a value, yield it
    // 2: halt           // Then halt
    // 3: panic          // Landmine
    // 4: call 7         // Outer function: call inner function at address 7
    // 5: yield          // Outer function's value is whatever the inner call produced
    // 6: halt           // Outer function exhausted once the inner call is
    // 7: yield          // Inner function: yield translation_unit (the inner call's value)
    // 8: halt           // Inner function exhausted
    const instructions = [_]Instruction{
        Instruction{ .call = 4 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .call = 7 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once: the inner call produces translation_unit, the
    // outer call passes it through as its own value, and the top-level
    // caller yields it once.
    try ctx.expectMatchKinds(&[_][]const u8{
        "translation_unit",
    });
}

test "call/ret: preserves environment correctly" {
    const source =
        \\ void foo() {}
    ;

    // The continuation after a call-yield resumes in the caller's
    // environment (as of the call site), not the callee's -- so variable_id
    // 1 seen after the call reflects the caller's own later assignment, not
    // any mutation the callee made to its (independent, copied) binding of
    // the same id. variable_id 3, only ever assigned inside the callee,
    // stays invisible to the caller.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "original" } } } },
        Instruction{ .call = 7 },
        Instruction{ .asn = .{ .variable_id = 2, .source = .{ .literal = Literal{ .string = "after" } } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 2 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 3 } } },
        Instruction{ .halt = {} },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "modified" } } } },
        Instruction{ .asn = .{ .variable_id = 3, .source = .{ .literal = Literal{ .string = "local" } } } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
