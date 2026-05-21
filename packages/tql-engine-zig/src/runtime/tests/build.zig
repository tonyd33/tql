const std = @import("std");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ValueSource = types.ValueSource;
const Value = types.Value;

const TestContext = @import("./test_helpers.zig").TestContext;

test "build: record" {
    const source = "void foo() {}";
    const instructions = [_]Instruction{
        .{ .begin_build = .record },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .string = "alice" } },
                .name = "name",
            },
        },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .kind_id = 42 } },
                .name = "kind",
            },
        },
        .{ .end_build = 1 },
        .{ .yield = .{ .source = .{ .variable_id = 1 } } },
        .{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const rec = (try ctx.runtime.next()).?.record;
    try std.testing.expectEqual(rec.rc, 1);
    try std.testing.expectEqual(rec.value.map.count(), 2);
    try std.testing.expectEqualStrings(rec.value.map.get("name").?.string, "alice");
    try std.testing.expectEqual(rec.value.map.get("kind").?.kind_id, 42);

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "build: list" {
    const source = "void foo() {}";
    const instructions = [_]Instruction{
        .{ .begin_build = .list },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .string = "a" } },
                .name = null,
            },
        },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .string = "b" } },
                .name = null,
            },
        },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .string = "c" } },
                .name = null,
            },
        },
        .{ .end_build = 7 },
        .{ .yield = .{ .source = .{ .variable_id = 7 } } },
        .{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const lst = (try ctx.runtime.next()).?.list;
    try std.testing.expectEqual(lst.value.items.items.len, 3);
    try std.testing.expectEqualStrings(lst.value.items.items[0].string, "a");
    try std.testing.expectEqualStrings(lst.value.items.items[1].string, "b");
    try std.testing.expectEqualStrings(lst.value.items.items[2].string, "c");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "build: nested list of list" {
    const source = "void foo() {}";
    const instructions = [_]Instruction{
        .{ .begin_build = .list },
        .{
            .push_build = .{
                .source = .{ .literal = .{ .string = "inner-elem" } },
                .name = null,
            },
        },
        .{ .end_build = 1 },

        .{ .begin_build = .list },
        .{
            .push_build = .{
                .source = .{ .variable_id = 1 },
                .name = null,
            },
        },
        .{
            .push_build = .{
                .source = .{ .variable_id = 1 },
                .name = null,
            },
        },
        .{ .end_build = 2 },
        .{ .yield = .{ .source = .{ .variable_id = 2 } } },
        .{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const outer = (try ctx.runtime.next()).?.list;
    try std.testing.expectEqual(outer.value.items.items.len, 2);

    // Both outer entries share the same inner Rc(List)
    const inner_a = outer.value.items.items[0].list;
    const inner_b = outer.value.items.items[1].list;
    try std.testing.expectEqual(inner_a, inner_b);

    // env holds 1 ref on inner under var 1, outer.items hold 2 more
    try std.testing.expectEqual(inner_a.rc, 3);
    try std.testing.expectEqual(inner_a.value.items.items.len, 1);
    try std.testing.expectEqualStrings(inner_a.value.items.items[0].string, "inner-elem");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}
