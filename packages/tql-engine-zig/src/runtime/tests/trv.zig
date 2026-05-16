const std = @import("std");
const ts = @import("tree-sitter");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ValueSource = types.ValueSource;
const NodeValueSource = types.NodeValueSource;

const TestContext = @import("./test_helpers.zig").TestContext;

extern fn tree_sitter_c() callconv(.c) *ts.Language;

test "trv: children depth 1" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{ "function_definition", "function_definition" });
}

test "trv: children depth 2" {
    const source =
        \\ int a;
        \\ int b;
    ;

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{ "primitive_type", "identifier", "primitive_type", "identifier" });
}

test "trv: descendants" {
    const source =
        \\ void foo() {
        \\   int a;
        \\ }
    ;

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .descendant = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
        "primitive_type",
        "function_declarator",
        "identifier",
        "parameter_list",
        "compound_statement",
        "declaration",
        "primitive_type",
        "identifier",
    });
}

test "trv: descendants with child" {
    const source =
        \\ void foo() {}
        \\ void bar() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .trv = Axis{ .descendant = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{
        "primitive_type",
        "function_declarator",
        "identifier",
        "parameter_list",
        "compound_statement",
        "primitive_type",
        "function_declarator",
        "identifier",
        "parameter_list",
        "compound_statement",
    });
}

test "trv: field" {
    const source =
        \\ void foo() {}
    ;

    const language = tree_sitter_c();
    defer language.destroy();
    const declarator_field_id = language.fieldIdForName("declarator");

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } }, // Get function_definition
        Instruction{ .trv = Axis{ .field = declarator_field_id } }, // Get declarator field
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"function_declarator"});
}

test "trv: field with multiple declarations" {
    const source =
        \\ int a, b, c;
    ;

    const language = tree_sitter_c();
    defer language.destroy();
    const declarator_field_id = language.fieldIdForName("declarator");

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .trv = Axis{ .field = declarator_field_id } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should find all three declarators (a, b, c)
    try ctx.expectMatchKinds(&[_][]const u8{ "identifier", "identifier", "identifier" });
}

test "trv: variable_id with node" {
    const source =
        \\ void foo() {}
    ;

    // First, trv to a child and save the current node to a variable
    // Then trv to a descendant, then trv back to the saved node and yield
    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } }, // Get function_definition
        Instruction{
            .asn = .{
                .variable_id = 1,
                .source = ValueSource{ .node = NodeValueSource.this }, // Save current node
            },
        },
        Instruction{ .trv = Axis{ .descendant = {} } }, // Navigate away to descendants
        Instruction{ .trv = Axis{ .variable_id = 1 } }, // trv back to the stored node
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield the saved function_definition node for each descendant
    // The function has 5 descendants (primitive_type, function_declarator, identifier, parameter_list, compound_statement)
    // So we get 5 yields of function_definition (one per descendant)
    try ctx.expectMatchKinds(&[_][]const u8{
        "function_definition",
        "function_definition",
        "function_definition",
        "function_definition",
        "function_definition",
    });
}

test "trv: variable_id with missing variable" {
    const source =
        \\ void foo() {}
    ;

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .variable_id = 999 } }, // Variable doesn't exist
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches since the variable doesn't exist
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "trv: empty node has no children" {
    const source = ""; // Empty source

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } }, // Try to get children (none exist)
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches since there are no children
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "trv: empty traversal then yield" {
    const source = ""; // Empty source

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } }, // Try to get children (none exist)
        Instruction{ .yield = .{} }, // This should not execute
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches - trv with no results terminates the branch
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "trv: empty traversal with halt after" {
    const source = ""; // Empty source

    const instructions = [_]Instruction{
        Instruction{ .trv = Axis{ .child = {} } }, // Try to get children (none exist)
        Instruction{ .halt = .{} }, // This should not execute
        Instruction{ .yield = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches - trv with no results terminates the branch
    try ctx.expectMatchKinds(&[_][]const u8{});
}
