const std = @import("std");
const Allocator = std.mem.Allocator;

const ts = @import("tree-sitter");
const ds = @import("../ds.zig");
const Rc = ds.Rc;

const pcre2 = @import("../pcre2.zig");

const types = @import("./types.zig");
const FieldId = types.FieldId;
const Address = types.Address;
const Symbol = types.Symbol;
const VariableId = types.VariableId;
const NodeKindId = types.NodeKindId;
const Point = types.Point;
const Range = types.Range;
const Value = types.Value;
const Environment = types.Environment;
const Boundary = types.Boundary;
const State = types.State;
const Frame = types.Frame;
const Stack = types.Stack;
const RuntimeError = types.RuntimeError;
const ChildIterator = types.ChildIterator;
const FieldIterator = types.FieldIterator;
const DescendantIterator = types.DescendantIterator;
const SplitIterator = types.SplitIterator;
const Axis = types.Axis;
const NodeValueSource = types.NodeValueSource;
const ValueSource = types.ValueSource;
const Instruction = types.Instruction;
const Vector = types.Vector;
const Record = types.Record;
const List = types.List;

pub const Runtime = struct {
    const Self = @This();

    tree: *ts.Tree,
    source: []const u8,
    allocator: std.mem.Allocator,

    instructions: []const Instruction,
    regexes: []const pcre2.Regex,

    stack: Stack,

    pub fn init(x: struct {
        tree: *ts.Tree,
        source: []const u8,
        instructions: []const Instruction,
        regexes: []const pcre2.Regex,
        allocator: std.mem.Allocator,
    }) Self {
        return Self{
            .tree = x.tree,
            .source = x.source,
            .instructions = x.instructions,
            .regexes = x.regexes,
            .stack = Stack.empty,
            .allocator = x.allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit(self.allocator);
    }

    // TODO: This can just be part of init probably
    pub fn exec(self: *Self) !void {
        const env = try Environment.Cell.create(self.allocator);
        self.stack.clearAndFree(self.allocator);
        try self.stack.append(
            self.allocator,
            Frame{
                .state = State{
                    .pc = 0,
                    .node = self.tree.rootNode(),
                    .environment = env,
                },
                .boundary = Boundary{ .root = {} },
            },
        );
    }

    fn deinitFrame(self: *Self) void {
        const frame = &self.stack.items[self.stack.items.len - 1];

        frame.state.environment.dereference(self.allocator);

        if (frame.split) |*split| {
            split.iterator.deinit();
        }

        if (frame.state.build) |build| {
            switch (build) {
                .record => |rc| rc.dereference(self.allocator),
                .list => |rc| rc.dereference(self.allocator),
            }
        }

        self.stack.shrinkRetainingCapacity(self.stack.items.len - 1);
    }

    fn getSource(self: *Self, state: State, vs: ValueSource) Value {
        return switch (vs) {
            .literal => |v| v,
            .node => |n| switch (n) {
                .this => {
                    return Value{ .node = state.node };
                },
                .text => {
                    const start_byte = state.node.startByte();
                    const end_byte = state.node.endByte();
                    const slice = self.source[start_byte..end_byte];
                    return Value{ .string = slice };
                },
                .kind => {
                    return Value{ .kind_id = state.node.kindId() };
                },
                .range => {
                    const range = state.node.range();
                    return Value{ .range = .{
                        .start_point = .{ .row = range.start_point.row, .column = range.start_point.column },
                        .end_point = .{ .row = range.end_point.row, .column = range.end_point.column },
                        .start_byte = range.start_byte,
                        .end_byte = range.end_byte,
                    } };
                },
            },
            .variable_id => |v| state.environment.get(v) orelse Value{ .nothing = {} },
        };
    }

    /// Handle probe boundary logic for halt/trv failure or yield
    /// Returns true if a probe boundary was found and handled
    /// If yield_semantics is true: exists succeeds, nexists fails
    /// If yield_semantics is false: nexists succeeds, exists fails
    fn handleProbeBoundary(self: *Self, yield_semantics: bool) bool {
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const search_frame = &self.stack.items[i];

            switch (search_frame.boundary) {
                .probe => |probe| {
                    const result: struct { unwind_to: usize, success_addr: ?u32 } = switch (probe) {
                        .nexists => |success_addr| if (yield_semantics) .{
                            .unwind_to = i - 1,
                            .success_addr = null,
                        } else .{
                            .unwind_to = i,
                            .success_addr = success_addr,
                        },
                        .exists => |success_addr| if (yield_semantics) .{
                            .unwind_to = i,
                            .success_addr = success_addr,
                        } else .{
                            .unwind_to = i - 1,
                            .success_addr = null,
                        },
                    };

                    while (self.stack.items.len > result.unwind_to) {
                        self.deinitFrame();
                    }
                    if (result.success_addr) |success_addr| {
                        const parent_frame = &self.stack.items[self.stack.items.len - 1];
                        parent_frame.state.pc = success_addr;
                    }
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn nextMatch(self: *Self) !?Value {
        outer: while (self.stack.items.len > 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];

            if (frame.split) |*split| {
                const has_next = split.iterator.next();
                if (has_next) {
                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try old_env.copy(self.allocator);
                    const env_copy_new_frame = try old_env.copy(self.allocator);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    try self.stack.append(self.allocator, Frame{
                        .state = State{
                            .pc = split.resume_pc,
                            .node = split.iterator.node(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = Boundary{ .passthrough = {} },
                    });
                } else {
                    self.deinitFrame();
                }
                continue;
            }

            if (frame.state.pc >= self.instructions.len) {
                self.deinitFrame();
                return error.ExecuteOutOfBounds;
            }

            if (frame.state.build != null) {
                switch (self.instructions[frame.state.pc]) {
                    .push_build, .end_build => {},
                    // Maybe there are more we can allow. Also we should return error not panic
                    else => {
                        @panic("Invalid program");
                    },
                }
            }

            switch (self.instructions[frame.state.pc]) {
                .noop => {
                    frame.state.pc += 1;
                },
                .halt => |halt_inst| {
                    const should_halt = switch (halt_inst.condition) {
                        .always => true,
                        .relates => frame.state.negate_flag,
                        .not_relates => !frame.state.negate_flag,
                    };

                    if (should_halt) {
                        if (self.handleProbeBoundary(false)) {
                            continue :outer;
                        }
                        frame.state.pc += 1;
                        self.deinitFrame();
                    } else {
                        frame.state.pc += 1;
                    }
                },
                .trv => |axis| {
                    frame.state.pc += 1;

                    // Special handling for variable_id, no iterator.
                    // NOTE: But maybe it should for uniformity...? I imagine it's
                    // inefficient though...
                    if (axis == .variable_id) {
                        const var_id = axis.variable_id;
                        const maybe_value = frame.state.environment.get(var_id);
                        if (maybe_value) |value| {
                            switch (value) {
                                .node => |node| {
                                    frame.state.node = node;
                                    continue;
                                },
                                else => {},
                            }
                        }

                        // I guess there is a question of whether this should error though.
                        // What semantically correct TQL query would even allow for this?
                        self.deinitFrame();
                        continue;
                    }

                    const maybe_iterator: ?SplitIterator = switch (axis) {
                        .child => blk: {
                            const iter = ChildIterator.init(frame.state.node);
                            break :blk if (iter) |i| SplitIterator{ .child = i } else null;
                        },
                        .descendant => blk: {
                            const iter = DescendantIterator.init(frame.state.node);
                            break :blk if (iter) |i| SplitIterator{ .descendant = i } else null;
                        },
                        .field => |field_id| blk: {
                            const iter = FieldIterator.init(frame.state.node, field_id);
                            break :blk if (iter) |i| SplitIterator{ .field = i } else null;
                        },
                        .variable_id => unreachable,
                    };

                    if (maybe_iterator) |iterator| {
                        // THe next loop iteration is supposed to handle this.
                        frame.split = .{
                            .iterator = iterator,
                            .resume_pc = frame.state.pc,
                        };
                        continue;
                    } else {
                        const hit_boundary = self.handleProbeBoundary(false);
                        if (hit_boundary) {
                            continue;
                        } else {
                            // Terminate branch.
                            self.deinitFrame();
                        }
                    }
                },
                .asn => |x| {
                    frame.state.pc += 1;
                    const value = self.getSource(frame.state, x.source);
                    switch (value) {
                        // NOTE: Maybe we should panic here.
                        .nothing => {},
                        else => {
                            const old_env = frame.state.environment;
                            const new_environment = try old_env.copyPut(
                                self.allocator,
                                x.variable_id,
                                value.clone(),
                            );
                            frame.state.environment = new_environment;
                            old_env.dereference(self.allocator);
                        },
                    }
                },
                .rel => |x| {
                    frame.state.pc += 1;
                    const a_value = self.getSource(frame.state, x.a);
                    const b_value = self.getSource(frame.state, x.b);
                    const relates = switch (x.relation) {
                        .equals => a_value.eql(b_value),
                        // The panics should be caught during bytecode compilation.
                        .like => switch (a_value) {
                            .string => |str| switch (b_value) {
                                .regex => |*regex| regex.do_test(str),
                                else => @panic("rel: type mismatch - expected regex on right side"),
                            },
                            else => @panic("rel: type mismatch - expected string on left side"),
                        },
                        .lt, .gt => {
                            @panic("todo: lt/gt not implemented");
                        },
                    };
                    frame.state.negate_flag = relates;
                },
                .yield => |source| {
                    if (self.handleProbeBoundary(true)) {
                        continue :outer;
                    }
                    frame.state.pc += 1;
                    return self.getSource(frame.state, source.source);
                },
                .probe => |probe_inst| {
                    frame.state.pc += 1;

                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try old_env.copy(self.allocator);
                    const env_copy_new_frame = try old_env.copy(self.allocator);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    const boundary = switch (probe_inst.mode) {
                        .exists => Boundary{ .probe = .{ .exists = probe_inst.on_success } },
                        .nexists => Boundary{ .probe = .{ .nexists = probe_inst.on_success } },
                    };

                    try self.stack.append(self.allocator, Frame{
                        .state = State{
                            .pc = frame.state.pc,
                            .node = frame.state.node,
                            .environment = env_copy_new_frame,
                        },
                        .boundary = boundary,
                    });
                },
                .call => |target_address| {
                    frame.state.pc += 1;

                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try old_env.copy(self.allocator);
                    const env_copy_new_frame = try old_env.copy(self.allocator);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    try self.stack.append(self.allocator, Frame{
                        .state = State{
                            .pc = target_address,
                            .node = frame.state.node,
                            .environment = env_copy_new_frame,
                        },
                        .boundary = Boundary{ .call = {} },
                    });
                },
                .ret => {
                    var i: usize = self.stack.items.len;
                    while (i > 0) {
                        i -= 1;
                        const search_frame = &self.stack.items[i];

                        // NOTE: I'm not confident this is right... what's supposed to happen
                        // when piercing a probe boundary through a ret?
                        if (search_frame.boundary == .call) {
                            while (self.stack.items.len > i) {
                                self.deinitFrame();
                            }

                            break;
                        }
                    } else {
                        @panic("stack corruption: ret without call");
                    }
                },
                .jmp => |jmp_inst| {
                    const should_jump = switch (jmp_inst.mode) {
                        .always => true,
                        .relates => frame.state.negate_flag,
                        .not_relates => !frame.state.negate_flag,
                    };

                    if (should_jump) {
                        frame.state.pc = jmp_inst.address;
                    } else {
                        frame.state.pc += 1;
                    }
                },
                .begin_build => |vector| {
                    frame.state.pc += 1;
                    switch (vector) {
                        .record => {
                            const rc = try Rc(Record).create(self.allocator, Record.init(self.allocator));
                            frame.state.build = .{ .record = rc };
                        },
                        .list => {
                            const rc = try Rc(List).create(self.allocator, List.init());
                            frame.state.build = .{ .list = rc };
                        },
                    }
                },
                .push_build => |info| {
                    frame.state.pc += 1;
                    const build = if (frame.state.build) |b| b else @panic("Invalid program");
                    const value = self.getSource(frame.state, info.source).clone();
                    switch (build) {
                        .record => |rc| {
                            const name = info.name orelse @panic("Invalid program");
                            try rc.value.map.put(name, value);
                        },
                        .list => |rc| {
                            try rc.value.items.append(self.allocator, value);
                        },
                    }
                },
                .end_build => |variable_id| {
                    frame.state.pc += 1;
                    const build = if (frame.state.build) |b| b else @panic("Invalid program");
                    frame.state.build = null;
                    const value: Value = switch (build) {
                        .record => |rc| .{ .record = rc },
                        .list => |rc| .{ .list = rc },
                    };
                    const old_env = frame.state.environment;
                    const new_env = try old_env.copyPut(self.allocator, variable_id, value);
                    frame.state.environment = new_env;
                    old_env.dereference(self.allocator);
                },
                .panic => {
                    @panic("panic instruction executed");
                },
            }
        }

        return null;
    }
};
