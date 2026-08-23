const std = @import("std");
const ts = @import("tree-sitter");

const pcre2 = @import("../../regex.zig");

const types = @import("../types.zig");
const Value = types.Value;

const ir = @import("../../ir.zig");
const Instruction = ir.Instruction;
const Axis = ir.Axis;
const Relation = ir.Relation;
const Literal = ir.Literal;

const TestContext = @import("./test_helpers.zig").TestContext;

extern fn tree_sitter_c() callconv(.c) *ts.Language;

// rel stores its bool result in `dest` (variable_id 2) to avoid clobbering state.value.
// jmp then reads variable_id 2 to decide whether to branch.
//   negate=false → jump when dest is TRUE  ("pass if true")
//   negate=true  → jump when dest is FALSE ("pass if false")
//
// Pattern for "halt if false" (require relation to hold):
//   rel { ..., dest = 2 }
//   jmp { address=N, source={variable_id=2}, negate=false }  // skip halt if true
//   halt
//   N: yield / ...
//
// Pattern for "halt if true" (require relation to NOT hold):
//   rel { ..., dest = 2 }
//   jmp { address=N, source={variable_id=2}, negate=true }   // skip halt if false
//   halt
//   N: yield / ...

test "rel: equals with matching strings" {
    const source = "int x;";

    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = false } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: not equals with matching strings" {
    const source = "int x;";

    // Strings equal → bool true in dest=2. "halt if true": jmp(skip, negate=true) skips halt when false; true → fall to halt.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not equals with different strings" {
    const source = "int x;";

    // Strings differ → false in dest=2. "halt if true": jmp(yield, negate=true) → taken (value==false) → yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "world" } } } },
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: like with regex matching" {
    const source = "int x;";

    var regex = try pcre2.Regex.compile("hel.*");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello world" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .regex = regex } } } },
        Instruction{ .rel = .{ .relation = Relation.like, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = false } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: like with regex not matching" {
    const source = "int x;";

    var regex = try pcre2.Regex.compile("^foo.*");
    defer regex.deinit();

    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "bar baz" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .regex = regex } } } },
        Instruction{ .rel = .{ .relation = Relation.like, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = false } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not like with regex matching" {
    const source = "int x;";

    var regex = try pcre2.Regex.compile(".*world");
    defer regex.deinit();

    // Match → true in dest=2. "halt if true": jmp(yield, negate=true) NOT taken → halt.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello world" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .regex = regex } } } },
        Instruction{ .rel = .{ .relation = Relation.like, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: not like with regex not matching" {
    const source = "int x;";

    var regex = try pcre2.Regex.compile("^xyz.*");
    defer regex.deinit();

    // No match → false in dest=2. "halt if true": jmp(yield, negate=true) taken → yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello world" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .regex = regex } } } },
        Instruction{ .rel = .{ .relation = Relation.like, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = true } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: halt inside nexists probe should succeed" {
    const source = "int x;";

    // Strings differ → false in dest=3. "halt if false": jmp(6, negate=false) NOT taken → halt.
    // nexists probe: halt → probe succeeds → resumes at 9.
    const instructions = [_]Instruction{
        // 0: nexists probe
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 9 } },
        // 1-2: assign different values
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "world" } } } },
        // 3: rel → false, store in var 3
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 3 } },
        // 4: jmp to 6 if true; false → not taken → fall to halt
        Instruction{ .jmp = .{ .address = 6, .source = .{ .variable_id = 3 }, .negate = false } },
        // 5: halt → nexists sees halt → success → resume at 9
        Instruction{ .halt = {} },
        // 6: would be reached if rel was true
        Instruction{ .jmp = .{ .address = 7 } },
        // 7-8: unreachable in this test
        Instruction{ .panic = {} },
        Instruction{ .panic = {} },
        // 9: probe succeeded
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "rel: halt inside exists probe should fail" {
    const source = "int x;";

    // Strings differ → false in dest=3. jmp not taken → halt.
    // exists probe: halt means failure → no yield.
    const instructions = [_]Instruction{
        // 0: exists probe
        Instruction{ .probe = .{ .data = .exists, .resume_address = 8 } },
        // 1-2: assign different values
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .string = "hello" } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .string = "world" } } } },
        // 3: rel → false, store in var 3
        Instruction{ .rel = .{ .relation = Relation.equals, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 3 } },
        // 4: jmp past halt if true; false → not taken → halt
        Instruction{ .jmp = .{ .address = 6, .source = .{ .variable_id = 3 }, .negate = false } },
        // 5: halt → exists probe fails
        Instruction{ .halt = {} },
        // 6-7: unreachable
        Instruction{ .panic = {} },
        Instruction{ .panic = {} },
        // 8: unreachable (probe failure kills the branch)
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "rel: numeric comparisons" {
    const source = "";

    // 1 < 2 → true in dest=2. jmp(yield, negate=false) taken → yield.
    const instructions = [_]Instruction{
        Instruction{ .asn = .{ .variable_id = 0, .source = .{ .literal = Literal{ .int = 1 } } } },
        Instruction{ .asn = .{ .variable_id = 1, .source = .{ .literal = Literal{ .int = 2 } } } },
        Instruction{ .rel = .{ .relation = Relation.lt, .a = .{ .variable_id = 0 }, .b = .{ .variable_id = 1 }, .dest = 2 } },
        Instruction{ .jmp = .{ .address = 5, .source = .{ .variable_id = 2 }, .negate = false } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
