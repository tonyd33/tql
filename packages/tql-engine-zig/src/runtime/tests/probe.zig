const std = @import("std");

const types = @import("../types.zig");

const ir = @import("../../ir.zig");
const Instruction = ir.Instruction;
const Axis = ir.Axis;

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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 3 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 2 } },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 3 } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 2 } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 4 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 3 } },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should yield once (probe succeeded - no children found)
    try ctx.expectMatchKinds(&[_][]const u8{"translation_unit"});
}

test "probe: call is not transparent to yield - exists probe body sees no yield" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe exists on_success=6    // Start exists probe
    // 1: call 4                       // Call function
    // 2: halt                         // After call returns (only reached if call yields)
    // 3: panic                        // Landmine
    // 4: yield                        // Function: this is the call's return value,
    //                                 // NOT visible to the enclosing probe
    // 5: halt                         // Function exhausted (call produces exactly one value)
    // 6: panic                        // Landmine (would be probe's success address)
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .exists, .resume_address = 6 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Unlike the old ret-based call, a call boundary now intercepts yields
    // from its callee -- they become the call's return values, consumed by
    // the caller's continuation, never visible to a probe wrapping the call
    // site. The callee's yield resumes the continuation (halt at pc 2), the
    // call is then exhausted, and the probe body terminates having never
    // seen a yield itself: the exists probe fails.
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: halt across boundary" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe nexists on_success=4   // Start nexists probe
    // 1: call 3                       // Call function
    // 2: panic                        // Landmine
    // 3: halt                         // Halt (across call boundary)
    // 4: yield                        // After probe succeeds
    // 5: halt                         // Terminate root
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 4 } },
        Instruction{ .call = 3 },
        Instruction{ .panic = {} },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
    // 1: yield                       // Caller continuation: yield the call's value
    // 2: halt
    // 3: probe exists on_success=6   // Function: start exists probe
    // 4: yield                       // Yield inside probe (signals success);
    //                                // this yield is caught by the probe,
    //                                // which is nearer than the call boundary
    // 5: halt
    // 6: yield                       // Function's return value (the call's value)
    // 7: halt                        // Function exhausted
    const instructions = [_]Instruction{
        Instruction{ .call = 3 },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .probe = .{ .data = .exists, .resume_address = 6 } },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 6 } },
        Instruction{ .probe = .{ .data = .exists, .resume_address = 4 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 6 } },
        Instruction{ .probe = .{ .data = .exists, .resume_address = 4 } },
        Instruction{ .yield = .{} },
        Instruction{ .panic = {} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 4 } },
        Instruction{ .call = 5 },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .yield = .{} },
        Instruction{ .halt = {} },
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
    // 5: panic                        // Landmine
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .exists, .resume_address = 6 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (exists probe fails because halt in call doesn't yield)
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
        Instruction{ .probe = .{ .data = .exists, .resume_address = 5 } },
        Instruction{ .call = 4 },
        Instruction{ .halt = {} },
        Instruction{ .panic = {} },
        Instruction{ .trv = Axis{ .child = {} } },
        Instruction{ .panic = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();

    // Should have no matches (exists probe fails: no yield inside body).
    try ctx.expectMatchKinds(&[_][]const u8{});
}

test "probe: aggregate list collects yielded values" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe aggregate(var=1, list) on_success=4
    // 1: yield "a"
    // 2: yield "b"
    // 3: halt
    // 4: yield var 1   // the collected list
    // 5: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .{ .aggregate = .{ .variable = 1, .kind = .list } }, .resume_address = 4 } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "a" } } } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "b" } } } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const lst = (try ctx.runtime.next()).?.list;
    try std.testing.expectEqual(lst.value.items.items.len, 2);
    try std.testing.expectEqualStrings(lst.value.items.items[0].string, "a");
    try std.testing.expectEqualStrings(lst.value.items.items[1].string, "b");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
}

test "probe: aggregate record collects alternating key/value yields" {
    const source =
        \\ void foo() {}
    ;

    // Program:
    // 0: probe aggregate(var=1, record) on_success=6
    // 1: yield "name"
    // 2: yield "alice"
    // 3: yield "role"
    // 4: yield "admin"
    // 5: halt
    // 6: yield var 1   // the collected record
    // 7: halt
    const instructions = [_]Instruction{
        Instruction{ .probe = .{ .data = .{ .aggregate = .{ .variable = 1, .kind = .record } }, .resume_address = 6 } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "name" } } } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "alice" } } } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "role" } } } },
        Instruction{ .yield = .{ .source = .{ .literal = .{ .string = "admin" } } } },
        Instruction{ .halt = {} },
        Instruction{ .yield = .{ .source = .{ .variable_id = 1 } } },
        Instruction{ .halt = {} },
    };

    var ctx = try TestContext.init(.{ .source = source, .instructions = &instructions });
    defer ctx.deinit();
    try ctx.runtime.exec();

    const rec = (try ctx.runtime.next()).?.record;
    try std.testing.expectEqual(rec.value.map.count(), 2);
    try std.testing.expectEqualStrings(rec.value.map.get("name").?.string, "alice");
    try std.testing.expectEqualStrings(rec.value.map.get("role").?.string, "admin");

    try std.testing.expectEqual(try ctx.runtime.next(), null);
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
        Instruction{ .probe = .{ .data = .nexists, .resume_address = 4 } },
        Instruction{ .call = 5 },
        Instruction{ .halt = {} },
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
