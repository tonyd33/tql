const std = @import("std");

const types = @import("../types.zig");
const Instruction = types.Instruction;
const Axis = types.Axis;
const ProbeMode = types.ProbeMode;

const TestContext = @import("./test_helpers.zig").TestContext;

test "probe: exists with yield - continues after probe" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=3    // Start exists probe
    // 1: yield                        // Yield inside probe (signals success)
    // 2: panic                        // Landmine
    // 3: yield                        // After probe succeeds
    // 4: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 3 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once after probe succeeds
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: exists with halt - terminates branch" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=2    // Start exists probe
    // 1: halt                         // Halt inside probe (signals failure)
    // 2: panic                        // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 2 } },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (probe failed)
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: exists with traversal that succeeds" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=4    // Start exists probe
    // 1: trv child                    // Try to get child
    // 2: yield                        // If child exists, yield (signals success)
    // 3: halt                         // After traversal
    // 4: yield                        // After probe succeeds
    // 5: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (probe succeeds because child exists)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: exists with traversal that fails" {
    const source = "";

    // Program:
    // 0: probe exists on_success=4    // Start exists probe
    // 1: trv child                    // Try to get child (fails - no children)
    // 2: panic                        // Landmine
    // 3: halt
    // 4: panic                        // Landmine
    // 5: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (probe failed - no children)
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: nexists with yield - terminates branch" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe nexists on_success=3    // Start nexists probe
    // 1: yield                         // Yield inside probe (signals failure for nexists)
    // 2: halt
    // 3: panic                         // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 3 } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (probe found something, which is failure for nexists)
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: nexists with halt - continues after probe" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe nexists on_success=2    // Start nexists probe
    // 1: halt                          // Halt inside probe (signals success for nexists)
    // 2: yield                         // After probe succeeds, yield
    // 3: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 2 } },
        Instruction{ .halt = .{} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once after probe succeeds
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: nexists with traversal that succeeds" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe nexists on_success=4    // Start nexists probe
    // 1: trv child                     // Try to get child (succeeds)
    // 2: yield                         // Yield (signals failure for nexists)
    // 3: halt
    // 4: panic                         // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (probe found children, which is failure for nexists)
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: nexists with traversal that fails" {
    const source = "";

    // Program:
    // 0: probe nexists on_success=3    // Start nexists probe
    // 1: trv child                     // Try to get child (fails - no children)
    // 2: panic                         // Landmine
    // 3: yield                         // After probe succeeds (no children found)
    // 4: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 3 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (probe succeeded - no children found)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: call inside exists probe" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=6    // Start exists probe
    // 1: call 4                       // Call function
    // 2: halt                         // After return from call
    // 3: panic                        // Landmine
    // 4: yield                        // Function: yield (signals success for exists)
    // 5: ret                          // Return from function
    // 6: yield                        // After probe succeeds
    // 7: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 6 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .ret = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (probe succeeds via call that yields)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: exists inside call" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: call 3                      // Call function
    // 1: yield                       // After return
    // 2: halt
    // 3: probe exists on_success=6   // Function: start exists probe
    // 4: yield                       // Yield inside probe (signals success)
    // 5: halt
    // 6: ret                         // Return from function
    const instructions = [_]Instruction{
        Instruction{ .call = 3 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 6 } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once after return (probe succeeds inside function)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: nested probes - exists inside exists" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=6    // Outer exists probe
    // 1: probe exists on_success=4    // Inner exists probe
    // 2: yield                        // Yield inside inner probe
    // 3: panic                        // Landmine
    // 4: yield                        // After inner probe
    // 5: panic                        // Landmine
    // 6: yield                        // After outer probe
    // 7: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 6 } },
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 4 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (both probes succeed)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: nested probes - exists inside nexists" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe nexists on_success=6   // Outer nexists probe
    // 1: probe exists on_success=4    // Inner exists probe
    // 2: yield                        // Yield inside inner probe (succeeds inner, fails outer)
    // 3: panic                        // Landmine
    // 4: halt                         // After inner probe
    // 5: panic                        // Landmine
    // 6: yield                        // Yields
    // 7: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 6 } },
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 4 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield root
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: halt inside call inside nexists probe" {
    const source =
        \\ void foo() {}
    ;

    // halt inside a call body unwinds only the call frame; control resumes
    // in the probe body. If the probe body then halts (no yield ever), the
    // nexists probe is satisfied (no counterexample) and execution jumps to
    // on_success.
    //
    // Program:
    // 0: probe nexists on_success=4   // Start nexists probe
    // 1: call 5                       // Call function (creates call boundary)
    // 2: halt                         // After call returns: end probe body
    // 3: panic                        // Landmine (should not reach)
    // 4: yield                        // After probe succeeds
    // 5: halt                         // Function: halt (call exits, returns to PC 2)
    // 6: ret                          // Should not reach here
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 4 } },
        Instruction{ .call = 5 },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = .{} },
        Instruction{ .ret = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (nexists probe succeeds: no yield inside body).
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: halt inside call inside exists probe" {
    const source =
        \\ void foo() {}
    ;

    // Similar to above but with exists probe
    //
    // Program:
    // 0: probe exists on_success=6    // Start exists probe
    // 1: call 4                       // Call function (creates call boundary)
    // 2: halt                         // After call returns
    // 3: panic                        // Landmine
    // 4: halt                         // Function: halt (should signal failure for exists)
    // 5: ret                          // Go back
    // 6: panic                        // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 6 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .halt = .{} },
        Instruction{ .ret = {} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (exists probe fails because halt in call doesn't yield)
    // Currently this test will FAIL because halt doesn't search for the exists boundary
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: trv fails inside call inside exists probe" {
    const source = ""; // Empty source - no children

    // trv failure inside a call exits only the call frame; control resumes
    // in the probe body. If the probe body then halts (no yield ever), the
    // exists probe fails (no match) and the parent's branch fails too.
    //
    // Program:
    // 0: probe exists on_success=5    // Start exists probe
    // 1: call 4                       // Call function
    // 2: halt                         // After call returns: end probe body
    // 3: panic                        // Landmine
    // 4: trv child                    // Function: fails - no children (exits call)
    // 5: panic                        // Landmine (probe-success; never reached)
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.exists, .on_success = 5 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (exists probe fails: no yield inside body).
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: trv fails inside call inside nexists probe" {
    const source = ""; // Empty source - no children

    // trv failure inside a call exits only the call frame; control resumes
    // in the probe body. If the probe body then halts (no yield ever), the
    // nexists probe succeeds (no counterexample).
    //
    // Program:
    // 0: probe nexists on_success=4   // Start nexists probe
    // 1: call 5                       // Call function
    // 2: halt                         // After call returns: end probe body
    // 3: panic                        // Landmine
    // 4: yield                        // After probe succeeds
    // 5: trv child                    // Function: fails - no children (exits call)
    // 6: panic                        // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .mode = ProbeMode.nexists, .on_success = 4 } },
        Instruction{ .call = 5 },
        Instruction{ .halt = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (nexists probe succeeds: no yield inside body).
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}
