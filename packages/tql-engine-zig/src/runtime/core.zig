const std = @import("std");
const Allocator = std.mem.Allocator;

const ts = @import("tree-sitter");
const ds = @import("../ds.zig");
const Rc = ds.Rc;

const pcre2 = @import("../regex.zig");

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
const SingletonIterator = types.SingletonIterator;
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

    fn getActiveProbeBoundaryIndex(self: *Self) ?usize {
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const search_frame = self.stack.items[i];

            switch (search_frame.boundary) {
                .probe => return i,
                else => {},
            }
        }
        return null;
    }

    /// End the current logical branch and propagate up the stack. Both
    /// implicit termination and explicit termination flow through here.
    fn handleBranchEnd(self: *Self) void {
        while (self.stack.items.len > 0) {
            const boundary = self.stack.items[self.stack.items.len - 1].boundary;
            self.deinitFrame();
            switch (boundary) {
                // Probe boundaries conditionally handle branch end.
                .probe => |probe| switch (probe) {
                    .exists => {
                        // Child terminated without yielding: probe failed.
                        // Propagate termination to the caller.
                        continue;
                    },
                    .nexists => |success_addr| {
                        // Child terminated without yielding: probe succeeded.
                        // Resume the caller at the success address.
                        const parent_frame = &self.stack.items[self.stack.items.len - 1];
                        parent_frame.state.pc = success_addr;
                        return;
                    },
                },
                // root and passthrough boundaries unconditionally handle
                // branch ends.
                .root, .passthrough => return,
                // call boundaries unconditionally propagate branch ends.
                .call => continue,
            }
        }
    }

    /// Handle yield by propagating up the stack. Returns true if the yield was
    /// handled.
    fn handleYield(self: *Self) bool {
        const idx = self.getActiveProbeBoundaryIndex() orelse return false;
        const probe = self.stack.items[idx].boundary.probe;

        while (self.stack.items.len > idx) {
            self.deinitFrame();
        }

        switch (probe) {
            .exists => |success_addr| {
                // Child yielded: probe succeeded. Resume the caller at the
                // success address.
                const parent_frame = &self.stack.items[self.stack.items.len - 1];
                parent_frame.state.pc = success_addr;
            },
            .nexists => {
                // Child yielded: probe failed. Propagate termination to the
                // caller.
                self.handleBranchEnd();
            },
        }

        return true;
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

    /// Returns next value or null if values are exhausted.
    /// Value is borrowed to callers and callers should not expect to reference
    /// the value after any other interaction with the runtime.
    pub fn next(self: *Self) !?Value {
        while (self.stack.items.len > 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            if (frame.state.pc >= self.instructions.len) {
                self.deinitFrame();
                return error.ExecuteOutOfBounds;
            }

            // This frame has become a generator for further frames. Once
            // the inner generator is exhausted, we end the branch.
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
                    self.handleBranchEnd();
                }
                continue;
            }

            if (frame.state.build != null) {
                switch (self.instructions[frame.state.pc]) {
                    .push_build, .end_build => {},
                    // The only valid syntax is:
                    // begin_build
                    // (zero or more push_build)
                    // end_build
                    // We may choose to expand, but the difficulty lies in if
                    // the frame changes while building or in cases of nested
                    // builds.
                    else => {
                        return error.InvalidBuildConstruction;
                    },
                }
            }

            switch (self.instructions[frame.state.pc]) {
                .noop => {
                    frame.state.pc += 1;
                },
                .halt => |halt_inst| {
                    frame.state.pc += 1;
                    const should_halt = switch (halt_inst.condition) {
                        .always => true,
                        .relates => frame.state.negate_flag,
                        .not_relates => !frame.state.negate_flag,
                    };

                    if (should_halt) {
                        self.handleBranchEnd();
                    }
                },
                .trv => |axis| {
                    // Convert this frame to being a generator.
                    frame.state.pc += 1;
                    const iterator: SplitIterator = switch (axis) {
                        .child => .{ .child = ChildIterator.init(frame.state.node) },
                        .descendant => .{ .descendant = DescendantIterator.init(frame.state.node) },
                        .field => |field_id| .{ .field = FieldIterator.init(frame.state.node, field_id) },
                        .variable_id => |var_id| blk: {
                            const maybe_value = frame.state.environment.get(var_id);
                            const maybe_node = try if (maybe_value) |v| switch (v) {
                                .node => |n| n,
                                .nothing => null,
                                else => error.UnexpectedType,
                            } else null;
                            break :blk .{ .singleton = SingletonIterator.init(maybe_node) };
                        },
                    };

                    frame.split = .{
                        .iterator = iterator,
                        .resume_pc = frame.state.pc,
                    };
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
                    const relates = try switch (x.relation) {
                        .equals => a_value.eql(b_value),
                        .like => switch (a_value) {
                            .string => |str| switch (b_value) {
                                .regex => |*regex| regex.do_test(str),
                                else => error.InvalidArguments,
                            },
                            else => error.InvalidArguments,
                        },
                        .lt => switch (a_value) {
                            .uint => |a_uint| switch (b_value) {
                                .uint => |b_uint| a_uint < b_uint,
                                else => error.InvalidArguments,
                            },
                            else => error.InvalidArguments,
                        },
                        .gt => switch (a_value) {
                            .uint => |a_uint| switch (b_value) {
                                .uint => |b_uint| a_uint > b_uint,
                                else => error.InvalidArguments,
                            },
                            else => error.InvalidArguments,
                        },
                    };
                    frame.state.negate_flag = relates;
                },
                .yield => |source| {
                    frame.state.pc += 1;
                    if (self.handleYield()) {
                        continue;
                    }
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
                    frame.state.pc += 1;
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
                        return error.StackCorruption;
                    }
                },
                .jmp => |jmp_inst| {
                    frame.state.pc += 1;
                    const should_jump = switch (jmp_inst.mode) {
                        .always => true,
                        .relates => frame.state.negate_flag,
                        .not_relates => !frame.state.negate_flag,
                    };

                    if (should_jump) {
                        frame.state.pc = jmp_inst.address;
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
                    const build = try if (frame.state.build) |b| b else error.InvalidBuildConstruction;
                    const value = self.getSource(frame.state, info.source).clone();
                    switch (build) {
                        .record => |rc| {
                            const name = try if (info.name) |n| n else error.InvalidBuildConstruction;
                            try rc.value.map.put(name, value);
                        },
                        .list => |rc| {
                            try rc.value.items.append(self.allocator, value);
                        },
                    }
                },
                .end_build => |variable_id| {
                    frame.state.pc += 1;
                    const build = try if (frame.state.build) |b| b else error.InvalidBuildConstruction;
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
                    return error.PanicInstruction;
                },
            }
        }

        return null;
    }
};
