const std = @import("std");
const testing = std.testing;
const core = @import("../core.zig");
const runtime = @import("../../runtime.zig");

test "VariableTable: getOrPut creates new variables" {
    var table = core.VariableTable.init(testing.allocator);
    defer table.deinit();

    const id1 = try table.getOrPut("@class");
    const id2 = try table.getOrPut("@name");
    const id3 = try table.getOrPut("@method");

    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id2);
    try testing.expectEqual(@as(runtime.VariableId, 2), id3);
}

test "VariableTable: getOrPut returns existing variable" {
    var table = core.VariableTable.init(testing.allocator);
    defer table.deinit();

    const id1 = try table.getOrPut("@class");
    const id2 = try table.getOrPut("@class");
    const id3 = try table.getOrPut("@name");
    const id4 = try table.getOrPut("@class");

    try testing.expectEqual(id1, id2);
    try testing.expectEqual(id1, id4);
    try testing.expectEqual(@as(runtime.VariableId, 0), id1);
    try testing.expectEqual(@as(runtime.VariableId, 1), id3);
}

test "VariableTable: get returns existing variable" {
    var table = core.VariableTable.init(testing.allocator);
    defer table.deinit();

    _ = try table.getOrPut("@class");
    _ = try table.getOrPut("@name");

    try testing.expectEqual(@as(runtime.VariableId, 0), table.get("@class").?);
    try testing.expectEqual(@as(runtime.VariableId, 1), table.get("@name").?);
}

test "VariableTable: get returns null for non-existent variable" {
    var table = core.VariableTable.init(testing.allocator);
    defer table.deinit();

    try testing.expectEqual(@as(?runtime.VariableId, null), table.get("@class"));
}

test "InstructionBuilder: emit basic instructions" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.emit(.yield);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    var program = try builder.build();
    defer program.deinit();

    try testing.expectEqual(@as(usize, 2), program.instructions.len);
    try testing.expect(program.instructions[0] == .yield);
    try testing.expect(program.instructions[1].halt.condition == .always);
}

test "InstructionBuilder: createLabel and markLabel" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label1 = builder.createLabel();
    const label2 = builder.createLabel();

    try testing.expectEqual(@as(u32, 0), label1);
    try testing.expectEqual(@as(u32, 1), label2);

    try builder.emit(.yield);
    try builder.markLabel(label1);
    try builder.emit(.{ .halt = .{ .condition = .always } });
    try builder.markLabel(label2);

    var program = try builder.build();
    defer program.deinit();

    // Verify labels were marked at correct addresses
    try testing.expectEqual(@as(runtime.Address, 1), builder.resolved_labels.get(label1).?);
    try testing.expectEqual(@as(runtime.Address, 2), builder.resolved_labels.get(label2).?);
}

test "InstructionBuilder: emitJump with forward reference" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit jump before marking the label (forward reference)
    try builder.emitJump(target_label, .always);
    try builder.emit(.yield);
    try builder.markLabel(target_label);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    var program = try builder.build();
    defer program.deinit();

    // Jump should be resolved to address 2 (the halt instruction)
    try testing.expectEqual(@as(usize, 3), program.instructions.len);
    try testing.expectEqual(@as(runtime.Address, 2), program.instructions[0].jmp.address);
    // Check mode by converting to int
    try testing.expectEqual(@as(u2, 0), @intFromEnum(program.instructions[0].jmp.mode));
}

test "InstructionBuilder: emitJump with backward reference" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit jump after marking the label (backward reference)
    try builder.markLabel(target_label);
    try builder.emit(.yield);
    try builder.emitJump(target_label, .relates);

    var program = try builder.build();
    defer program.deinit();

    // Jump should be resolved to address 0 (the yield instruction)
    try testing.expectEqual(@as(usize, 2), program.instructions.len);
    try testing.expectEqual(@as(runtime.Address, 0), program.instructions[1].jmp.address);
    // Check mode by converting to int (relates = 1)
    try testing.expectEqual(@as(u2, 1), @intFromEnum(program.instructions[1].jmp.mode));
}

test "InstructionBuilder: emitProbe with forward reference" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const success_label = builder.createLabel();

    // Emit probe before marking the success label
    try builder.emitProbe(.exists, success_label);
    try builder.emit(.yield);
    try builder.emit(.{ .halt = .{ .condition = .always } });
    try builder.markLabel(success_label);
    try builder.emit(.yield);

    var program = try builder.build();
    defer program.deinit();

    // Probe should be resolved to address 3 (the second yield)
    try testing.expectEqual(@as(usize, 4), program.instructions.len);
    try testing.expectEqual(@as(runtime.Address, 3), program.instructions[0].probe.on_success);
    try testing.expectEqual(runtime.ProbeMode.exists, program.instructions[0].probe.mode);
}

test "InstructionBuilder: multiple jumps to same label" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Multiple jumps to the same label
    try builder.emitJump(target_label, .always);
    try builder.emit(.yield);
    try builder.emitJump(target_label, .relates);
    try builder.emit(.yield);
    try builder.markLabel(target_label);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    var program = try builder.build();
    defer program.deinit();

    // Both jumps should be resolved to address 4 (the halt instruction)
    try testing.expectEqual(@as(usize, 5), program.instructions.len);
    try testing.expectEqual(@as(runtime.Address, 4), program.instructions[0].jmp.address);
    try testing.expectEqual(@as(runtime.Address, 4), program.instructions[2].jmp.address);
}

test "InstructionBuilder: unresolved label returns error" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label = builder.createLabel();

    // Emit jump to label but never mark it
    try builder.emitJump(label, .always);
    try builder.emit(.yield);

    // build() should fail with UnresolvedLabel
    const result = builder.build();
    try testing.expectError(error.UnresolvedLabel, result);
}

test "InstructionBuilder: complex control flow with multiple labels" {
    var builder = core.InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const loop_start = builder.createLabel();
    const success = builder.createLabel();
    const end = builder.createLabel();

    try builder.markLabel(loop_start);
    try builder.emit(.{ .trv = .{ .descendant = .{ .allow_anonymous = false } } });
    try builder.emitJump(success, .relates);
    try builder.emitJump(loop_start, .always);
    try builder.markLabel(success);
    try builder.emit(.yield);
    try builder.emitJump(end, .always);
    try builder.markLabel(end);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    var program = try builder.build();
    defer program.deinit();

    try testing.expectEqual(@as(usize, 6), program.instructions.len);
    try testing.expectEqual(@as(runtime.Address, 3), program.instructions[1].jmp.address); // Jump to success (addr 3)
    try testing.expectEqual(@as(runtime.Address, 0), program.instructions[2].jmp.address); // Jump to loop_start (addr 0)
    try testing.expectEqual(@as(runtime.Address, 5), program.instructions[4].jmp.address); // Jump to end (addr 5)
}

const ts = @import("tree-sitter");

extern fn tree_sitter_typescript() *ts.Language;

test "Compiler: init and deinit" {
    const language = tree_sitter_typescript();
    var comp = core.Compiler.init(testing.allocator, language);
    defer comp.deinit();

    try testing.expect(comp.variables.next_id == 0);
}
