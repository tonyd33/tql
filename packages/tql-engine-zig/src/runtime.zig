const std = @import("std");
const Allocator = std.mem.Allocator;

const ts = @import("tree-sitter");

const ds = @import("ds.zig");
const value_mod = @import("value.zig");
const pcre2 = @import("regex.zig");
const rt = @import("runtime/types.zig");
const ir = @import("ir.zig");

const Point = value_mod.Point;
const Range = value_mod.Range;
const Value = value_mod.Value;

const Boundary = rt.Boundary;
const State = rt.State;
const Frame = rt.Frame;
const Stack = rt.Stack;
const RuntimeError = rt.RuntimeError;
const ChildIterator = rt.ChildIterator;
const FieldIterator = rt.FieldIterator;
const DescendantIterator = rt.DescendantIterator;
const SplitIterator = rt.SplitIterator;
const SingletonIterator = rt.SingletonIterator;
const Record = rt.Record;
const List = rt.List;
const Environment = rt.Environment;

const ValueSource = ir.ValueSource;
const Instruction = ir.Instruction;

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
                    .value = .{ .node = self.tree.rootNode() },
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

        switch (frame.boundary) {
            .probe => |probe| switch (probe.data) {
                .exists, .nexists => {},
                .aggregate => |agg| switch (agg.value) {
                    .list => |list| list.dereference(self.allocator),
                },
            },
            .root, .passthrough, .call => {},
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
    fn handleBranchEnd(self: *Self) !void {
        while (self.stack.items.len > 0) {
            const boundary = self.stack.items[self.stack.items.len - 1].boundary;
            switch (boundary) {
                // Probe boundaries conditionally handle branch end.
                .probe => |probe| switch (probe.data) {
                    .exists => {
                        // Child terminated without yielding: probe failed.
                        // Propagate termination to the caller.
                        self.deinitFrame();
                        continue;
                    },
                    .nexists => {
                        // Child terminated without yielding: probe succeeded.
                        // Resume the caller at the success address.
                        self.deinitFrame();
                        const parent_frame = &self.stack.items[self.stack.items.len - 1];
                        parent_frame.state.pc = probe.resume_address;
                        return;
                    },
                    .aggregate => |agg| {
                        const list_ref = switch (agg.value) {
                            .list => |list| list.reference(),
                        };
                        self.deinitFrame();
                        const parent_frame = &self.stack.items[self.stack.items.len - 1];
                        const old_env = parent_frame.state.environment;
                        const value = rt.Value{ .list = list_ref };
                        const new_env = try old_env.copyPut(self.allocator, agg.variable, value);
                        parent_frame.state.environment = new_env;
                        old_env.dereference(self.allocator);
                        parent_frame.state.pc = probe.resume_address;
                        return;
                    },
                },
                // root and passthrough boundaries unconditionally handle
                // branch ends.
                .root, .passthrough => {
                    self.deinitFrame();
                    return;
                },
                // call boundaries unconditionally propagate branch ends.
                .call => {
                    self.deinitFrame();
                    continue;
                },
            }
        }
    }

    /// Handle yield by propagating up the stack. Returns true if the yield was
    /// handled.
    fn handleYield(self: *Self, value: rt.Value) !bool {
        const idx = self.getActiveProbeBoundaryIndex() orelse return false;
        const probe = self.stack.items[idx].boundary.probe;

        switch (probe.data) {
            .exists => {
                // Child yielded: probe succeeded. Resume the caller at the
                // success address.
                while (self.stack.items.len > idx) {
                    self.deinitFrame();
                }
                const parent_frame = &self.stack.items[self.stack.items.len - 1];
                parent_frame.state.pc = probe.resume_address;
            },
            .nexists => {
                // Child yielded: probe failed. Propagate termination to the
                // caller.
                while (self.stack.items.len > idx) {
                    self.deinitFrame();
                }
                try self.handleBranchEnd();
            },
            .aggregate => |agg| switch (agg.value) {
                .list => |list| try list.value.items.append(self.allocator, value.clone()),
            },
        }
        return true;
    }

    fn getSource(self: *Self, state: State, vs: ValueSource) !rt.Value {
        return switch (vs) {
            .literal => |v| switch (v) {
                .nothing => .nothing,
                .bool => |b| rt.Value{ .bool = b },
                .uint => |u| rt.Value{ .uint = u },
                .string => |s| rt.Value{ .string = s },
                .kind_id => |k| rt.Value{ .kind_id = k },
                .field_id => |f| rt.Value{ .field_id = f },
                .regex => |r| rt.Value{ .regex = r },
            },
            .current => |c| switch (c) {
                .value => state.value,
                .text => switch (state.value) {
                    .node => |node| blk: {
                        const slice = self.source[node.startByte()..node.endByte()];
                        break :blk rt.Value{ .string = slice };
                    },
                    else => error.UnexpectedType,
                },
                .kind => switch (state.value) {
                    .node => |node| rt.Value{ .kind_id = node.kindId() },
                    else => error.UnexpectedType,
                },
                .range => switch (state.value) {
                    .node => |node| blk: {
                        const range = node.range();
                        break :blk rt.Value{ .range = .{
                            .start_point = .{ .row = range.start_point.row, .column = range.start_point.column },
                            .end_point = .{ .row = range.end_point.row, .column = range.end_point.column },
                            .start_byte = range.start_byte,
                            .end_byte = range.end_byte,
                        } };
                    },
                    else => error.UnexpectedType,
                },
            },
            .variable_id => |v| state.environment.get(v) orelse rt.Value{ .nothing = {} },
        };
    }

    /// Returns next value or null if values are exhausted.
    /// Value is borrowed to callers and callers should not expect to reference
    /// the value after any other interaction with the runtime.
    pub fn next(self: *Self) !?rt.Value {
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
                            .value = split.iterator.value(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = Boundary{ .passthrough = {} },
                    });
                } else {
                    try self.handleBranchEnd();
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
                .halt => {
                    frame.state.pc += 1;
                    try self.handleBranchEnd();
                },
                .trv => |axis| {
                    // Convert this frame to being a generator.
                    frame.state.pc += 1;
                    const iterator: SplitIterator = switch (axis) {
                        .child => switch (frame.state.value) {
                            .node => |n| .{ .child = ChildIterator.init(n) },
                            else => return error.UnexpectedType,
                        },
                        .descendant => switch (frame.state.value) {
                            .node => |n| .{ .descendant = DescendantIterator.init(n) },
                            else => return error.UnexpectedType,
                        },
                        .field => |field_id| switch (frame.state.value) {
                            .node => |n| .{ .field = FieldIterator.init(n, field_id) },
                            else => return error.UnexpectedType,
                        },
                        .value_source => |vs| blk: {
                            const value = try self.getSource(frame.state, vs);
                            break :blk .{ .singleton = SingletonIterator.init(
                                if (value == .nothing) null else value,
                            ) };
                        },
                    };

                    frame.split = .{
                        .iterator = iterator,
                        .resume_pc = frame.state.pc,
                    };
                },
                .asn => |x| {
                    frame.state.pc += 1;
                    const value = try self.getSource(frame.state, x.source);
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
                    const a_value = try self.getSource(frame.state, x.a);
                    const b_value = try self.getSource(frame.state, x.b);
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
                    const result = rt.Value{ .bool = relates };
                    if (x.dest) |var_id| {
                        const old_env = frame.state.environment;
                        const new_env = try old_env.copyPut(self.allocator, var_id, result);
                        frame.state.environment = new_env;
                        old_env.dereference(self.allocator);
                    } else {
                        frame.state.value = result;
                    }
                },
                .yield => |source| {
                    frame.state.pc += 1;
                    const value = try self.getSource(frame.state, source.source);
                    if (try self.handleYield(value)) {
                        continue;
                    } else {
                        return value;
                    }
                },
                .probe => |probe_inst| {
                    frame.state.pc += 1;

                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try old_env.copy(self.allocator);
                    const env_copy_new_frame = try old_env.copy(self.allocator);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    const boundary = switch (probe_inst.data) {
                        .exists => Boundary{ .probe = .{
                            .resume_address = probe_inst.resume_address,
                            .data = .exists,
                        } },
                        .nexists => Boundary{ .probe = .{
                            .resume_address = probe_inst.resume_address,
                            .data = .nexists,
                        } },
                        .aggregate => |spec| switch (spec.kind) {
                            .list => Boundary{
                                .probe = .{
                                    .resume_address = probe_inst.resume_address,
                                    .data = .{ .aggregate = .{
                                        .variable = spec.variable,
                                        .value = .{
                                            .list = try ds.Rc(List).create(self.allocator, List.init()),
                                        },
                                    } },
                                },
                            },
                        },
                    };

                    try self.stack.append(self.allocator, Frame{
                        .state = State{
                            .pc = frame.state.pc,
                            .value = frame.state.value,
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
                            .value = frame.state.value,
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
                    const should_jump = if (jmp_inst.source) |vs| blk: {
                        const val = try self.getSource(frame.state, vs);
                        const b = switch (val) {
                            .bool => |b| b,
                            else => return error.UnexpectedType,
                        };
                        break :blk (b != jmp_inst.negate);
                    } else true;
                    if (should_jump) frame.state.pc = jmp_inst.address;
                },
                .begin_build => |vector| {
                    frame.state.pc += 1;
                    switch (vector) {
                        .record => {
                            const rc = try ds.Rc(Record).create(self.allocator, Record.init(self.allocator));
                            frame.state.build = .{ .record = rc };
                        },
                        .list => {
                            const rc = try ds.Rc(List).create(self.allocator, List.init());
                            frame.state.build = .{ .list = rc };
                        },
                    }
                },
                .push_build => |info| {
                    frame.state.pc += 1;
                    const build = try if (frame.state.build) |b| b else error.InvalidBuildConstruction;
                    const value = (try self.getSource(frame.state, info.source)).clone();
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
                    const value: rt.Value = switch (build) {
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

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("runtime/tests.zig"));
}
