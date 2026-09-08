const std = @import("std");
const Allocator = std.mem.Allocator;

const ir = @import("../ir.zig");
const Instruction = ir.Instruction;
const VariableId = ir.VariableId;
const NodeKindId = ir.NodeKindId;
const FieldId = ir.FieldId;
const Address = ir.Address;
const Relation = ir.Relation;

const LabelId = u32;

// FIXME: this is scuffed and only exists because alt has two things to patch
const PatchField = enum { first, second };

const PendingPatch = struct {
    inst_index: usize,
    field: PatchField,
};

pub const InstructionBuilder = struct {
    instructions: std.ArrayList(Instruction),
    allocator: Allocator,
    pending_labels: std.AutoHashMap(u32, std.ArrayList(PendingPatch)),
    resolved_labels: std.AutoHashMap(u32, Address),
    next_label_id: u32,

    pub fn init(allocator: Allocator) InstructionBuilder {
        return .{
            .instructions = std.ArrayList(Instruction).empty,
            .allocator = allocator,
            .pending_labels = std.AutoHashMap(u32, std.ArrayList(PendingPatch)).init(allocator),
            .resolved_labels = std.AutoHashMap(u32, Address).init(allocator),
            .next_label_id = 0,
        };
    }

    pub fn deinit(self: *InstructionBuilder) void {
        self.instructions.deinit(self.allocator);

        var iter = self.pending_labels.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.pending_labels.deinit();

        self.resolved_labels.deinit();
    }

    pub fn createLabel(self: *InstructionBuilder) LabelId {
        const label_id = self.next_label_id;
        self.next_label_id += 1;
        return label_id;
    }

    pub fn markLabel(self: *InstructionBuilder, label_id: LabelId) error{OutOfMemory}!void {
        const address = @as(Address, @intCast(self.instructions.items.len));
        try self.resolved_labels.put(label_id, address);
    }

    pub fn emit(self: *InstructionBuilder, instruction: Instruction) Allocator.Error!void {
        try self.instructions.append(self.allocator, instruction);
    }

    fn registerPatch(self: *InstructionBuilder, label_id: LabelId, inst_index: usize, field: PatchField) Allocator.Error!void {
        const result = try self.pending_labels.getOrPut(label_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(PendingPatch).empty;
        }
        try result.value_ptr.append(self.allocator, .{ .inst_index = inst_index, .field = field });
    }

    pub fn emitJump(self: *InstructionBuilder, label_id: LabelId) Allocator.Error!void {
        const inst_index = self.instructions.items.len;
        try self.instructions.append(self.allocator, Instruction{ .jmp = .{ .address = 0 } });
        try self.registerPatch(label_id, inst_index, .first);
    }

    pub fn emitJumpCnd(self: *InstructionBuilder, source: ir.ValueSource, label_id: LabelId, negate: bool) Allocator.Error!void {
        const inst_index = self.instructions.items.len;
        try self.instructions.append(self.allocator, Instruction{ .jmp = .{ .address = 0, .source = source, .negate = negate } });
        try self.registerPatch(label_id, inst_index, .first);
    }

    pub fn emitCall(self: *InstructionBuilder, label_id: LabelId) Allocator.Error!void {
        const inst_index = self.instructions.items.len;
        try self.instructions.append(self.allocator, Instruction{ .call = 0 });
        try self.registerPatch(label_id, inst_index, .first);
    }

    pub fn emitMakeClosure(
        self: *InstructionBuilder,
        label_id: LabelId,
        arity: u8,
        param_vars_offset: u32,
        dest: VariableId,
    ) Allocator.Error!void {
        const inst_index = self.instructions.items.len;
        try self.instructions.append(self.allocator, Instruction{ .make_closure = .{
            .entry = 0,
            .arity = arity,
            .param_vars_offset = param_vars_offset,
            .dest = dest,
        } });
        try self.registerPatch(label_id, inst_index, .first);
    }

    pub fn emitProbe(self: *InstructionBuilder, data: ir.ProbeData, resume_label: LabelId) Allocator.Error!void {
        const inst_index = self.instructions.items.len;

        try self.instructions.append(self.allocator, Instruction{ .probe = .{
            .data = data,
            .resume_address = 0,
        } });

        try self.registerPatch(resume_label, inst_index, .first);
    }

    pub fn emitAlt(self: *InstructionBuilder, left_label: LabelId, right_label: LabelId) Allocator.Error!void {
        const inst_index = self.instructions.items.len;

        try self.instructions.append(self.allocator, Instruction{ .alt = .{
            .left_entry = 0,
            .right_entry = 0,
        } });

        try self.registerPatch(left_label, inst_index, .first);
        try self.registerPatch(right_label, inst_index, .second);
    }

    pub fn patch(self: *InstructionBuilder, allocator: std.mem.Allocator) error{
        OutOfMemory,
        UnresolvedLabel,
        InvalidLabelReference,
    }![]const Instruction {
        var pending_iter = self.pending_labels.iterator();
        // maybe don't mutate?
        while (pending_iter.next()) |entry| {
            const label_id = entry.key_ptr.*;
            const patches = entry.value_ptr.*;

            const address = self.resolved_labels.get(label_id) orelse {
                return error.UnresolvedLabel;
            };

            for (patches.items) |pending| {
                const inst = &self.instructions.items[pending.inst_index];
                switch (inst.*) {
                    .jmp => |*jmp| jmp.address = address,
                    .probe => |*probe| probe.resume_address = address,
                    .call => |*call| call.* = address,
                    .make_closure => |*mc| mc.entry = address,
                    .alt => |*alt| switch (pending.field) {
                        .first => alt.left_entry = address,
                        .second => alt.right_entry = address,
                    },
                    else => return error.InvalidLabelReference,
                }
            }
        }

        const instructions = try self.instructions.toOwnedSlice(allocator);
        return instructions;
    }
};

const testing = std.testing;

test "InstructionBuilder: emit basic instructions" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.emit(.{ .yield = .{ .source = .{ .current = .value } } });
    try builder.emit(.halt);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    try testing.expectEqual(2, instructions.len);
    try testing.expect(instructions[0] == .yield);
    try testing.expect(instructions[1] == .halt);
}

test "InstructionBuilder: createLabel and markLabel" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label1 = builder.createLabel();
    const label2 = builder.createLabel();

    try testing.expectEqual(0, label1);
    try testing.expectEqual(1, label2);

    try builder.emit(.{ .yield = .{ .source = .{ .current = .value } } });
    try builder.markLabel(label1);
    try builder.emit(.halt);
    try builder.markLabel(label2);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Verify labels were marked at correct addresses
    try testing.expectEqual(1, builder.resolved_labels.get(label1).?);
    try testing.expectEqual(2, builder.resolved_labels.get(label2).?);
}

test "InstructionBuilder: emitJump with forward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit unconditional jump before marking the label (forward reference)
    try builder.emitJump(target_label);
    try builder.emit(.{ .yield = .{} });
    try builder.markLabel(target_label);
    try builder.emit(.halt);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Jump should be resolved to address 2 (the halt instruction)
    try testing.expectEqual(3, instructions.len);
    try testing.expectEqual(2, instructions[0].jmp.address);
    try testing.expectEqual(instructions[0].jmp.source, null);
}

test "InstructionBuilder: emitJumpCnd with backward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit conditional jump after marking the label (backward reference)
    try builder.markLabel(target_label);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJumpCnd(.{ .current = .value }, target_label, false);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Jump should be resolved to address 0 (the yield instruction)
    try testing.expectEqual(2, instructions.len);
    try testing.expectEqual(0, instructions[1].jmp.address);
    try testing.expectEqual(instructions[1].jmp.negate, false);
}

test "InstructionBuilder: emitProbe with forward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const success_label = builder.createLabel();

    // Emit probe before marking the success label
    try builder.emitProbe(.exists, success_label);
    try builder.emit(.{ .yield = .{} });
    try builder.emit(.halt);
    try builder.markLabel(success_label);
    try builder.emit(.{ .yield = .{} });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Probe should be resolved to address 3 (the second yield)
    try testing.expectEqual(4, instructions.len);
    try testing.expectEqual(3, instructions[0].probe.resume_address);
    try testing.expectEqual(ir.ProbeData.exists, instructions[0].probe.data);
}

test "InstructionBuilder: multiple jumps to same label" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Multiple jumps to the same label
    try builder.emitJump(target_label);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJumpCnd(.{ .current = .value }, target_label, false);
    try builder.emit(.{ .yield = .{} });
    try builder.markLabel(target_label);
    try builder.emit(.halt);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Both jumps should be resolved to address 4 (the halt instruction)
    try testing.expectEqual(5, instructions.len);
    try testing.expectEqual(4, instructions[0].jmp.address);
    try testing.expectEqual(4, instructions[2].jmp.address);
}

test "InstructionBuilder: unresolved label returns error" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label = builder.createLabel();

    // Emit jump to label but never mark it
    try builder.emitJump(label);
    try builder.emit(.{ .yield = .{} });

    // build() should fail with UnresolvedLabel
    const result = builder.patch(testing.allocator);
    try testing.expectError(error.UnresolvedLabel, result);
}

test "InstructionBuilder: complex control flow with multiple labels" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const loop_start = builder.createLabel();
    const success = builder.createLabel();
    const end = builder.createLabel();

    try builder.markLabel(loop_start);
    try builder.emit(.{ .trv = .{ .descendant = {} } });
    try builder.emitJumpCnd(.{ .current = .value }, success, false);
    try builder.emitJump(loop_start);
    try builder.markLabel(success);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJump(end);
    try builder.markLabel(end);
    try builder.emit(.halt);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    try testing.expectEqual(6, instructions.len);
    try testing.expectEqual(3, instructions[1].jmp.address); // Jump to success (addr 3)
    try testing.expectEqual(0, instructions[2].jmp.address); // Jump to loop_start (addr 0)
    try testing.expectEqual(5, instructions[4].jmp.address); // Jump to end (addr 5)
}
