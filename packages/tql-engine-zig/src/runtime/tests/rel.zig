const std = @import("std");
const ts = @import("tree-sitter");

const pcre2 = @import("../../pcre2.zig");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const Value = types.Value;
const NodeValueSource = types.NodeValueSource;
const Relation = types.Relation;

const TestContext = @import("./test_helpers.zig").TestContext;

extern fn tree_sitter_c() callconv(.c) *ts.Language;

test "rel: equals with matching strings" {
    const source = "int x;";

    // Assign two variables with the same string value, then test nequals
    // Since they're equal, equals should succeed and we get one match
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
        Instruction{ .halt = .{ .condition = .not_relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: not equals with matching strings" {
    const source = "int x;";

    // Assign two variables with the same string value, then test equals with not_relates halt
    // Since they're equal, flag is true, not_relates halt triggers
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
        Instruction{ .halt = .{ .condition = .relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not equals with different strings" {
    const source = "int x;";

    // Assign two variables with different string values, then test equals with not_relates halt
    // Since they're different, flag is false, not_relates halt doesn't trigger, we yield
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
        Instruction{ .halt = .{ .condition = .relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: like with regex matching" {
    const source = "int x;";

    // Assign a string and regex pattern, then test like (string ~ regex)
    var regex = try pcre2.Regex.compile("hel.*");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello world" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .regex = regex } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.like,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        Instruction{ .halt = .{ .condition = .not_relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: like with regex not matching" {
    const source = "int x;";

    // Assign a string and regex pattern, then test like (string ~ regex)
    // String doesn't match the pattern, so flag will be false
    var regex = try pcre2.Regex.compile("^foo.*");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "bar baz" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .regex = regex } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.like,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        Instruction{ .halt = .{ .condition = .not_relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not like with regex matching" {
    const source = "int x;";

    // Assign a string and regex pattern, then test like with relates halt
    // Since string matches the pattern, flag is true, relates halt triggers
    var regex = try pcre2.Regex.compile(".*world");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello world" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .regex = regex } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.like,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        Instruction{ .halt = .{ .condition = .relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not like with regex not matching" {
    const source = "int x;";

    // Assign a string and regex pattern, then test like with relates halt
    // Since string doesn't match, flag is false, relates halt doesn't trigger, we yield
    var regex = try pcre2.Regex.compile("^xyz.*");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello world" } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .regex = regex } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.like,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        Instruction{ .halt = .{ .condition = .relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: relates halt inside nexists probe should succeed" {
    const source = "int x;";

    // Test that relates halt (after rel failure) inside nexists probe triggers probe success
    // Stack: root -> nexists probe -> rel sets flag false -> relates halt triggers
    // Expected: nexists succeeds (halt means success), jumps to address 6, yields
    const instructions = [_]Instruction{
        // 0: Start nexists probe
        Instruction{
            .probe = .{
                .mode = .nexists,
                .on_success = 6, // Jump here if probe succeeds (halt)
            },
        },
        // 1: Inside probe - assign different values
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        // 2: Assign different value
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .string = "world" } },
        } },
        // 3: Test equals - this sets flag to false since strings are different
        Instruction{ .rel = .{
            .relation = Relation.equals,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        // 4: relates halt - triggers because flag is false
        Instruction{ .halt = .{ .condition = .not_relates } },
        // 5: This should never be reached
        Instruction{ .panic = {} },
        // 6: Probe succeeded, yield result
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: relates halt inside exists probe should fail" {
    const source = "int x;";

    // Test that relates halt (after rel failure) inside exists probe triggers probe failure
    // Stack: root -> exists probe -> rel sets flag false -> relates halt triggers
    // Expected: exists fails (halt means failure), entire branch terminates, no matches
    const instructions = [_]Instruction{
        // 0: Start exists probe
        Instruction{
            .probe = .{
                .mode = .exists,
                .on_success = 6, // Jump here if probe succeeds (yield happens)
            },
        },
        // 1: Inside probe - assign different values
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .string = "hello" } },
        } },
        // 2: Assign different value
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .string = "world" } },
        } },
        // 3: Test equals - this sets flag to false since strings are different
        Instruction{ .rel = .{
            .relation = Relation.equals,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        // 4: relates halt - triggers because flag is false
        Instruction{ .halt = .{ .condition = .not_relates } },
        // 5: This should never be reached
        Instruction{ .panic = {} },
        // 6: This should never be reached either
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Exists probe fails when halt happens, so we get no matches
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: numeric comparisons" {
    const source = "";

    const instructions = [_]Instruction{
        Instruction{ .asn = .{
            .variable_id = 0,
            .source = .{ .literal = Value{ .uint = 1 } },
        } },
        Instruction{ .asn = .{
            .variable_id = 1,
            .source = .{ .literal = Value{ .uint = 2 } },
        } },
        Instruction{ .rel = .{
            .relation = Relation.lt,
            .a = .{ .variable_id = 0 },
            .b = .{ .variable_id = 1 },
        } },
        Instruction{ .halt = .{ .condition = .not_relates } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
