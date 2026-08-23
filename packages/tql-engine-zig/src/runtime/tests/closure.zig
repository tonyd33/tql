const std = @import("std");

const types = @import("../types.zig");
const Value = types.Value;

const ir = @import("../../ir.zig");
const Instruction = ir.Instruction;
const Axis = ir.Axis;
const ValueSource = ir.ValueSource;
const Literal = ir.Literal;

const TestContext = @import("./test_helpers.zig").TestContext;

test "closure: make_closure then fully-saturated apply behaves like call" {
    const source = "void foo() {}";

    const param_var_arena = [_]ir.VariableId{100};

    const instructions = [_]Instruction{
        .{ .make_closure = .{ .entry = 5, .arity = 1, .param_vars_offset = 0, .dest = 1 } },
        .{ .apply = .{ .closure = .{ .variable_id = 1 }, .argument = .{ .literal = .{ .string = "hi" } } } },
        .{ .yield = .{} },
        .{ .halt = {} },
        .{ .panic = {} },
        .{ .yield = .{ .source = .{ .variable_id = 100 } } },
        .{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions, .param_var_arena = &param_var_arena });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const value = (try ctx.runtime.next()).?;
    try std.testing.expectEqualStrings(value.string, "hi");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "closure: partial application builds a smaller closure, no call" {
    const source = "void foo() {}";

    const param_var_arena = [_]ir.VariableId{ 100, 101 };

    const instructions = [_]Instruction{
        .{ .make_closure = .{ .entry = 7, .arity = 2, .param_vars_offset = 0, .dest = 1 } },
        .{ .apply = .{ .closure = .{ .variable_id = 1 }, .argument = .{ .literal = .{ .string = "first" } } } },
        .{ .asn = .{ .variable_id = 2, .source = .{ .current = .value } } },
        .{ .apply = .{ .closure = .{ .variable_id = 2 }, .argument = .{ .literal = .{ .string = "second" } } } },
        .{ .yield = .{} },
        .{ .halt = {} },
        .{ .panic = {} },
        .{ .yield = .{ .source = .{ .variable_id = 100 } } },
        .{ .yield = .{ .source = .{ .variable_id = 101 } } },
        .{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions, .param_var_arena = &param_var_arena });
    defer ctx.deinit();
    try ctx.runtime.exec();

    var value = (try ctx.runtime.next()).?;
    try std.testing.expectEqualStrings(value.string, "first");

    value = (try ctx.runtime.next()).?;
    try std.testing.expectEqualStrings(value.string, "second");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "closure: captures defining environment, not call-site environment" {
    const source = "void foo() {}";

    const param_var_arena = [_]ir.VariableId{100};

    const instructions = [_]Instruction{
        .{ .asn = .{ .variable_id = 50, .source = .{ .literal = .{ .string = "captured" } } } },
        .{ .make_closure = .{ .entry = 7, .arity = 1, .param_vars_offset = 0, .dest = 1 } },
        .{ .asn = .{ .variable_id = 50, .source = .{ .literal = .{ .string = "overwritten-after-capture" } } } },
        .{ .apply = .{ .closure = .{ .variable_id = 1 }, .argument = .{ .literal = .{ .string = "arg" } } } },
        .{ .yield = .{} },
        .{ .halt = {} },
        .{ .panic = {} },
        .{ .yield = .{ .source = .{ .variable_id = 50 } } },
        .{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions, .param_var_arena = &param_var_arena });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const value = (try ctx.runtime.next()).?;
    try std.testing.expectEqualStrings(value.string, "captured");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "closure: applied closure body can yield multiple times (multi-shot)" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const param_var_arena = [_]ir.VariableId{100};

    const instructions = [_]Instruction{
        .{ .make_closure = .{ .entry = 5, .arity = 1, .param_vars_offset = 0, .dest = 1 } },
        .{ .apply = .{ .closure = .{ .variable_id = 1 }, .argument = .{ .literal = .{ .string = "x" } } } },
        .{ .yield = .{} },
        .{ .halt = {} },
        .{ .panic = {} },
        .{ .trv = Axis{ .child = {} } },
        .{ .yield = .{} },
        .{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions, .param_var_arena = &param_var_arena });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
        "function_definition",
    });
}

test "closure: partial application does not push a call frame" {
    const source = "void foo() {}";

    const param_var_arena = [_]ir.VariableId{ 100, 101 };

    const instructions = [_]Instruction{
        .{ .make_closure = .{ .entry = 99, .arity = 2, .param_vars_offset = 0, .dest = 1 } },
        .{ .apply = .{ .closure = .{ .variable_id = 1 }, .argument = .{ .literal = .{ .string = "only-one" } } } },
        .{ .yield = .{} },
        .{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions, .param_var_arena = &param_var_arena });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const value = (try ctx.runtime.next()).?;
    try std.testing.expect(value == .closure);
    try std.testing.expectEqual(value.closure.value.arity, 2);
    try std.testing.expectEqual(value.closure.value.applied.len, 1);
    try std.testing.expectEqualStrings(value.closure.value.applied[0].string, "only-one");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}
