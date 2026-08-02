const std = @import("std");

const types = @import("../types.zig");
const Value = types.Value;

const ir = @import("../../ir.zig");
const Instruction = ir.Instruction;
const Axis = ir.Axis;
const ValueSource = ir.ValueSource;

const TestContext = @import("./test_helpers.zig").TestContext;

test "build: record" {
    const source = "void foo() {}";
    const instructions = [_]Instruction{
        .{ .probe = .{ .data = .{ .aggregate = .{ .variable = 1, .kind = .record } }, .resume_address = 6 } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "name" } } } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "alice" } } } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "kind" } } } },
        .{ .yield = .{ .source = .{ .literal = .{ .kind_id = 42 } } } },
        .{ .halt = {} },
        .{ .yield = .{ .source = .{ .variable_id = 1 } } },
        .{ .halt = {} },
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
        .{ .probe = .{ .data = .{ .aggregate = .{ .variable = 7, .kind = .list } }, .resume_address = 5 } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "a" } } } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "b" } } } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "c" } } } },
        .{ .halt = {} },
        .{ .yield = .{ .source = .{ .variable_id = 7 } } },
        .{ .halt = {} },
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
        // Build inner list into var 1
        .{ .probe = .{ .data = .{ .aggregate = .{ .variable = 1, .kind = .list } }, .resume_address = 3 } },
        .{ .yield = .{ .source = .{ .literal = .{ .string = "inner-elem" } } } },
        .{ .halt = {} },

        // Build outer list into var 2, pushing var 1 twice
        .{ .probe = .{ .data = .{ .aggregate = .{ .variable = 2, .kind = .list } }, .resume_address = 7 } },
        .{ .yield = .{ .source = .{ .variable_id = 1 } } },
        .{ .yield = .{ .source = .{ .variable_id = 1 } } },
        .{ .halt = {} },

        .{ .yield = .{ .source = .{ .variable_id = 2 } } },
        .{ .halt = {} },
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
