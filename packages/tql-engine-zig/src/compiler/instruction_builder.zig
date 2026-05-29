const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const runtime = @import("../runtime.zig");
const Condition = runtime.Condition;
const Instruction = runtime.Instruction;
const VariableId = runtime.VariableId;
const NodeKindId = runtime.NodeKindId;
const FieldId = runtime.FieldId;
const Address = runtime.Address;
const Relation = runtime.Relation;

const ast = @import("../ast.zig");
const pcre2 = @import("../regex.zig");

const LabelId = u32;

pub const InstructionBuilder = struct {
    instructions: std.ArrayList(Instruction),
    allocator: Allocator,
    pending_labels: std.AutoHashMap(u32, std.ArrayList(usize)),
    resolved_labels: std.AutoHashMap(u32, Address),
    next_label_id: u32,

    pub fn init(allocator: Allocator) InstructionBuilder {
        return .{
            .instructions = std.ArrayList(Instruction).empty,
            .allocator = allocator,
            .pending_labels = std.AutoHashMap(u32, std.ArrayList(usize)).init(allocator),
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
        return @as(LabelId, label_id);
    }

    pub fn markLabel(self: *InstructionBuilder, label_id: LabelId) error{OutOfMemory}!void {
        const address = @as(Address, @intCast(self.instructions.items.len));
        try self.resolved_labels.put(label_id, address);
    }

    pub fn emit(self: *InstructionBuilder, instruction: Instruction) Allocator.Error!void {
        try self.instructions.append(self.allocator, instruction);
    }

    pub fn emitJump(self: *InstructionBuilder, label_id: u32, mode: Condition) Allocator.Error!void {
        const inst_index = self.instructions.items.len;

        // placeholder
        try self.instructions.append(self.allocator, Instruction{ .jmp = .{ .address = 0, .mode = mode } });

        const result = try self.pending_labels.getOrPut(label_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize).empty;
        }
        try result.value_ptr.append(self.allocator, inst_index);
    }

    pub fn emitProbe(self: *InstructionBuilder, mode: runtime.ProbeMode, on_success_label: u32) Allocator.Error!void {
        const inst_index = self.instructions.items.len;

        try self.instructions.append(self.allocator, Instruction{ .probe = .{ .mode = mode, .on_success = 0 } });

        const result = try self.pending_labels.getOrPut(on_success_label);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize).empty;
        }
        try result.value_ptr.append(self.allocator, inst_index);
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
            const indices = entry.value_ptr.*;

            const address = self.resolved_labels.get(label_id) orelse {
                return error.UnresolvedLabel;
            };

            for (indices.items) |inst_index| {
                const inst = &self.instructions.items[inst_index];
                switch (inst.*) {
                    .jmp => |*jmp| jmp.address = address,
                    .probe => |*probe| probe.on_success = address,
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

    try builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
    try builder.emit(.{ .halt = .{ .condition = .always } });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    try testing.expectEqual(@as(usize, 2), instructions.len);
    try testing.expect(instructions[0] == .yield);
    try testing.expect(instructions[1].halt.condition == .always);
}

test "InstructionBuilder: createLabel and markLabel" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label1 = builder.createLabel();
    const label2 = builder.createLabel();

    try testing.expectEqual(@as(u32, 0), label1);
    try testing.expectEqual(@as(u32, 1), label2);

    try builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
    try builder.markLabel(label1);
    try builder.emit(.{ .halt = .{ .condition = .always } });
    try builder.markLabel(label2);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Verify labels were marked at correct addresses
    try testing.expectEqual(@as(runtime.Address, 1), builder.resolved_labels.get(label1).?);
    try testing.expectEqual(@as(runtime.Address, 2), builder.resolved_labels.get(label2).?);
}

test "InstructionBuilder: emitJump with forward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit jump before marking the label (forward reference)
    try builder.emitJump(target_label, .always);
    try builder.emit(.{ .yield = .{} });
    try builder.markLabel(target_label);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Jump should be resolved to address 2 (the halt instruction)
    try testing.expectEqual(@as(usize, 3), instructions.len);
    try testing.expectEqual(@as(runtime.Address, 2), instructions[0].jmp.address);
    // Check mode by converting to int
    try testing.expectEqual(@as(u2, 0), @intFromEnum(instructions[0].jmp.mode));
}

test "InstructionBuilder: emitJump with backward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Emit jump after marking the label (backward reference)
    try builder.markLabel(target_label);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJump(target_label, .relates);

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Jump should be resolved to address 0 (the yield instruction)
    try testing.expectEqual(@as(usize, 2), instructions.len);
    try testing.expectEqual(@as(runtime.Address, 0), instructions[1].jmp.address);
    // Check mode by converting to int (relates = 1)
    try testing.expectEqual(@as(u2, 1), @intFromEnum(instructions[1].jmp.mode));
}

test "InstructionBuilder: emitProbe with forward reference" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const success_label = builder.createLabel();

    // Emit probe before marking the success label
    try builder.emitProbe(.exists, success_label);
    try builder.emit(.{ .yield = .{} });
    try builder.emit(.{ .halt = .{ .condition = .always } });
    try builder.markLabel(success_label);
    try builder.emit(.{ .yield = .{} });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Probe should be resolved to address 3 (the second yield)
    try testing.expectEqual(@as(usize, 4), instructions.len);
    try testing.expectEqual(@as(runtime.Address, 3), instructions[0].probe.on_success);
    try testing.expectEqual(runtime.ProbeMode.exists, instructions[0].probe.mode);
}

test "InstructionBuilder: multiple jumps to same label" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const target_label = builder.createLabel();

    // Multiple jumps to the same label
    try builder.emitJump(target_label, .always);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJump(target_label, .relates);
    try builder.emit(.{ .yield = .{} });
    try builder.markLabel(target_label);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    // Both jumps should be resolved to address 4 (the halt instruction)
    try testing.expectEqual(@as(usize, 5), instructions.len);
    try testing.expectEqual(@as(runtime.Address, 4), instructions[0].jmp.address);
    try testing.expectEqual(@as(runtime.Address, 4), instructions[2].jmp.address);
}

test "InstructionBuilder: unresolved label returns error" {
    var builder = InstructionBuilder.init(testing.allocator);
    defer builder.deinit();

    const label = builder.createLabel();

    // Emit jump to label but never mark it
    try builder.emitJump(label, .always);
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
    try builder.emitJump(success, .relates);
    try builder.emitJump(loop_start, .always);
    try builder.markLabel(success);
    try builder.emit(.{ .yield = .{} });
    try builder.emitJump(end, .always);
    try builder.markLabel(end);
    try builder.emit(.{ .halt = .{ .condition = .always } });

    const instructions = try builder.patch(testing.allocator);
    defer testing.allocator.free(instructions);

    try testing.expectEqual(@as(usize, 6), instructions.len);
    try testing.expectEqual(@as(runtime.Address, 3), instructions[1].jmp.address); // Jump to success (addr 3)
    try testing.expectEqual(@as(runtime.Address, 0), instructions[2].jmp.address); // Jump to loop_start (addr 0)
    try testing.expectEqual(@as(runtime.Address, 5), instructions[4].jmp.address); // Jump to end (addr 5)
}
