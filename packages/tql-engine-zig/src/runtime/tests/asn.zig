const std = @import("std");
const expect = std.testing.expect;
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ValueSource = types.ValueSource;
const Value = types.Value;
const NodeValueSource = types.NodeValueSource;
const Range = types.Range;

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
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    var value = try ctx.runtime.next();
    try std.testing.expect(std.mem.eql(u8, value.?.string, "hi"));

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value, null);
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
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 2 } } },
        Instruction{ .yield = .{ .source = .{ .variable_id = 3 } } },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    var value = try ctx.runtime.next();
    try std.testing.expectEqualStrings(value.?.string, "void foo_bar() {}");

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value.?.kind_id, function_definition_kind_id);

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value.?.range, Range{
        .start_point = .{ .row = 0, .column = 1 },
        .end_point = .{ .row = 0, .column = 18 },
        .start_byte = 1,
        .end_byte = 18,
    });

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value, null);
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
        Instruction{ .yield = .{ .source = ValueSource{ .variable_id = 1 } } },
        Instruction{ .yield = .{ .source = ValueSource{ .variable_id = 2 } } },
        Instruction{ .yield = .{ .source = ValueSource{ .variable_id = 3 } } },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.runtime.exec();

    var value = try ctx.runtime.next();
    try std.testing.expectEqualStrings(value.?.string, "hi");

    value = try ctx.runtime.next();
    try std.testing.expectEqualStrings(value.?.string, "hi");

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value.?.nothing, {});

    value = try ctx.runtime.next();
    try std.testing.expectEqual(value, null);
}
