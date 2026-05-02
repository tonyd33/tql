const std = @import("std");
const expect = std.testing.expect;
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ValueSource = types.ValueSource;
const Value = types.Value;
const NodeValueSource = types.NodeValueSource;

const TestContext = @import("./test_helpers.zig").TestContext;

extern fn tree_sitter_c() callconv(.c) *ts.Language;

test "asn: literal" {
    const source =
        \\ void foo_bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = ValueSource{ .literal = Value{ .string = "hi" } },
        } },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    while (try ctx.runtime.nextMatch()) |match| {
        try expect(std.mem.eql(
            u8,
            match.environment.get(1).?.string,
            "hi",
        ));
    }
}

test "asn: node" {
    const source =
        \\ void foo_bar() {}
    ;

    const language = tree_sitter_c();
    defer language.destroy();
    const function_definition_kind_id = language.idForNodeKind("function_definition", true);

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = ValueSource{ .node = NodeValueSource.text },
        } },
        Instruction{ .asn = .{
            .variable_id = 2,
            .source = ValueSource{ .node = NodeValueSource.kind },
        } },
        Instruction{ .asn = .{
            .variable_id = 3,
            .source = ValueSource{ .node = NodeValueSource.range },
        } },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    while (try ctx.runtime.nextMatch()) |match| {
        try expect(std.mem.eql(
            u8,
            match.environment.get(1).?.string,
            "void foo_bar() {}",
        ));
        try expect(match.environment.get(2).?.kind_id == function_definition_kind_id);
        const range = match.environment.get(3).?.range;
        try expect(range.start_byte == 1);
        try expect(range.end_byte == 18);
    }
}

test "asn: variable" {
    const source =
        \\ void foo_bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = ValueSource{ .literal = Value{ .string = "hi" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 2,
            .source = ValueSource{ .variable_id = 1 },
        } },
        Instruction{ .asn = .{
            .variable_id = 3,
            .source = ValueSource{ .variable_id = 123 },
        } },
        Instruction{ .yield = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    while (try ctx.runtime.nextMatch()) |match| {
        try expect(std.mem.eql(
            u8,
            match.environment.get(1).?.string,
            "hi",
        ));
        try expect(std.mem.eql(
            u8,
            match.environment.get(2).?.string,
            "hi",
        ));
        try expect(match.environment.get(3) == null);
    }
}
