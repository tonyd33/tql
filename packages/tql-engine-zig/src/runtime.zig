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
const ListIterator = rt.ListIterator;
const Record = rt.Record;
const List = rt.List;
const Environment = rt.Environment;

const ValueSource = ir.ValueSource;
const Instruction = ir.Instruction;
const VariableId = ir.VariableId;

pub const Runtime = struct {
    const Self = @This();

    tree: *ts.Tree,
    source: []const u8,
    allocator: std.mem.Allocator,

    instructions: []const Instruction,
    regexes: []const pcre2.Regex,
    param_var_arena: []const VariableId,

    stack: Stack,
    profile: rt.Profile = .{},

    pub fn init(x: struct {
        tree: *ts.Tree,
        source: []const u8,
        instructions: []const Instruction,
        regexes: []const pcre2.Regex,
        param_var_arena: []const VariableId = &.{},
        allocator: std.mem.Allocator,
    }) Self {
        return Self{
            .tree = x.tree,
            .source = x.source,
            .instructions = x.instructions,
            .regexes = x.regexes,
            .param_var_arena = x.param_var_arena,
            .stack = Stack.empty,
            .allocator = x.allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit(self.allocator);
    }

    /// Every environment copy, put and lookup in the interpreter goes through
    /// these three, so the counters cannot drift from the real operations.
    fn envCopy(self: *Self, env: Environment.Cell) !Environment.Cell {
        self.profile.countEnvCopy();
        return env.copy(self.allocator);
    }

    fn envPut(self: *Self, env: Environment.Cell, key: VariableId, value: rt.Value) !Environment.Cell {
        self.profile.countEnvPut();
        return env.copyPut(self.allocator, key, value);
    }

    fn envGet(self: *Self, env: Environment.Cell, key: VariableId) ?rt.Value {
        self.profile.countEnvLookup();
        return env.get(key);
    }

    fn pushFrame(self: *Self, frame: Frame) !void {
        self.profile.countFrame();
        try self.stack.append(self.allocator, frame);
    }

    // TODO: This can just be part of init probably
    pub fn exec(self: *Self) !void {
        const env = try Environment.Cell.create(self.allocator);
        self.stack.clearAndFree(self.allocator);
        try self.pushFrame(Frame{
            .state = State{
                .pc = 0,
                .value = .{ .node = self.tree.rootNode() },
                .environment = env,
            },
            .boundary = Boundary{ .passthrough = {} },
        });
    }

    fn deinitFrame(self: *Self) void {
        const frame = &self.stack.items[self.stack.items.len - 1];

        // IMPROVE: look for a memory model that doesn't involve
        // cloning these in the first place. That might just be fundamentally
        // imppossible with heap-allocated values though
        frame.state.value.deinit(self.allocator);
        frame.state.environment.dereference(self.allocator);

        if (frame.split) |*split| {
            split.iterator.deinit(self.allocator);
        }

        switch (frame.boundary) {
            .exists, .nexists => {},
            .aggregate => |agg| switch (agg.value) {
                .list => |list| list.dereference(self.allocator),
                .record => |rec| rec.rc.dereference(self.allocator),
            },
            .passthrough, .call, .yield_return, .alt => {},
        }

        self.stack.shrinkRetainingCapacity(self.stack.items.len - 1);
    }

    /// Find the nearest frame that handles the yield effect.
    fn getActiveYieldHandlerIndex(self: *Self) ?usize {
        // NOTE: Consider maintaining stack(s) for effect handling to eliminate
        // linear searches while handling effects.
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const search_frame = self.stack.items[i];

            switch (search_frame.boundary) {
                // Regular yield effect handlers
                .exists, .nexists, .aggregate, .call, .alt => return i,
                // Special yield effect handling.
                // The yield_return frame had set up the index of the
                // boundary that should handle the next effect.
                // cf. `handleYield`
                .yield_return => |yr| {
                    // boundary_idx is the index of the original generator
                    // frame. We want to jump to boundary_idx - 1, and the
                    // beginning of the loop decrements i, so we have to set i
                    // to boundary_idx here.
                    i = yr.boundary_idx;
                },
                // No yield effect handling
                .passthrough => {},
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
                // root and passthrough boundaries unconditionally handle
                // branch ends.
                .passthrough => {
                    self.deinitFrame();
                    return;
                },
                .exists => {
                    // Child terminated without yielding: probe failed.
                    // Propagate termination to the caller.
                    self.deinitFrame();
                    continue;
                },
                .nexists => |nexists| {
                    // Child terminated without yielding: probe succeeded.
                    // Resume the caller at the success address.
                    self.deinitFrame();
                    const parent_frame = &self.stack.items[self.stack.items.len - 1];
                    parent_frame.state.pc = nexists.resume_address;
                    return;
                },
                .aggregate => |agg| {
                    const value: rt.Value = switch (agg.value) {
                        .list => |list| .{ .list = list.reference() },
                        .record => |rec| blk: {
                            std.debug.assert(rec.pending_key == null);
                            break :blk .{ .record = rec.rc.reference() };
                        },
                    };
                    self.deinitFrame();
                    const parent_frame = &self.stack.items[self.stack.items.len - 1];
                    const old_env = parent_frame.state.environment;
                    const new_env = try self.envPut(old_env, agg.variable, value);
                    parent_frame.state.environment = new_env;
                    old_env.dereference(self.allocator);
                    parent_frame.state.pc = agg.resume_address;
                    return;
                },
                // call boundaries unconditionally propagate branch ends.
                // the callee is exhausted, so the call produced no values.
                .call => {
                    self.deinitFrame();
                    continue;
                },
                // A caller's continuation after a generator yield terminated.
                // The frame now exposed below did not itself terminate and may
                // continue generating frames that may yield.
                // cf. `handleYield`
                .yield_return => {
                    self.deinitFrame();
                    return;
                },
                .alt => |alt| switch (alt.phase) {
                    .left => {
                        const idx = self.stack.items.len - 1;
                        const frame = &self.stack.items[idx];
                        const caller = self.stack.items[idx - 1].state;

                        frame.state.value.deinit(self.allocator);
                        frame.state.environment.dereference(self.allocator);
                        frame.state.value = caller.value.clone();
                        frame.state.environment = try self.envCopy(caller.environment);
                        frame.state.pc = alt.right_entry;
                        if (frame.split) |*split| {
                            split.iterator.deinit(self.allocator);
                            frame.split = null;
                        }
                        frame.boundary = .{ .alt = .{
                            .resume_address = alt.resume_address,
                            .right_entry = alt.right_entry,
                            .phase = .right,
                        } };
                        return;
                    },
                    .right => {
                        self.deinitFrame();
                        continue;
                    },
                },
            }
        }
    }

    /// Handle yield by propagating up the stack. Returns true if the yield was
    /// handled.
    fn handleYield(self: *Self, value: rt.Value) !bool {
        const idx = self.getActiveYieldHandlerIndex() orelse return false;

        switch (self.stack.items[idx].boundary) {
            .exists => |exists| {
                // Child yielded: probe succeeded. Resume the caller
                // at the success address.
                while (self.stack.items.len > idx) {
                    self.deinitFrame();
                }
                const parent_frame = &self.stack.items[self.stack.items.len - 1];
                parent_frame.state.pc = exists.resume_address;
            },
            .nexists => {
                // Child yielded: probe failed. Propagate termination
                // to the caller.
                while (self.stack.items.len > idx) {
                    self.deinitFrame();
                }
                try self.handleBranchEnd();
            },
            .aggregate => |agg| switch (agg.value) {
                .list => |list| try list.value.items.append(self.allocator, value.clone()),
                .record => |rec| {
                    const rec_ptr = &self.stack.items[idx].boundary.aggregate.value.record;
                    if (rec.pending_key) |key| {
                        try rec.rc.value.map.put(key, value.clone());
                        rec_ptr.pending_key = null;
                    } else {
                        const key = switch (value) {
                            .string => |s| s,
                            else => return error.InvalidArguments,
                        };
                        rec_ptr.pending_key = key;
                    }
                },
            },
            // The yield should resume at the continuation of the caller, with
            // the environment of the caller intact, but with the cursor set to
            // the yielded value.
            //
            // Naively, we may unwind all the way down to the caller's frame
            // and replace it, but this ends up destroying
            // continuation-generating frames in between. For example, consider
            // the following instructions:
            //
            // call N
            // trv X
            // yield
            //
            // Which may generate the following stack:
            //
            // | - | ------------ |
            // | . |  GENERATOR   | <- yield
            // | - | ------------ |
            // | . | .call        |
            // | - | ------------ |
            // | . |      ...     |
            // | - | ------------ |
            //
            // If trv X generated multiple continuations, unwinding to the call
            // frame would destroy the iterator on the first yield invocation,
            // which violates the semantics of the generator frame.
            //
            // We may consider allocating a separate stack to store yielded
            // values and collapse to the call frame once generation has
            // completed. The difficulty is that such a stack must live
            // orthogonal to the regular stack, which defeats purpose of the
            // stack altogether. (Though in cases like aggregation, we fall
            // back to this strategy)
            //
            // We instead place a frame representing the caller's continuation
            // on the stack such that yields "jump back" past the caller's
            // frame. Observe:
            //
            // | - | ------------ |
            // | . |      CUR     | <- 2. yield
            // | - | ------------ |
            // | . |      ...     |
            // | - | ------------ |
            // | . | .yield_return | <- 1b. place this frame now
            // | - | ------------ |
            // | . |  GENERATOR   | <- 1a. yield
            // | - | ------------ |
            // | . | .call        |
            // | - | ------------ |
            // | i |      ...     | <- 3. continue handling yield here
            // | - | ------------ |
            //
            // Upon the second yield and searching down the stack for a yield
            // effect handler, the yield_return frame is discovered and tells us
            // to jump right underneath the generator frame.
            //
            // Now we consider branch termination:
            //
            // | - | ------------ |
            // | . |      CUR     | <- 2. terminate
            // | - | ------------ |
            // | . |      ...     |
            // | - | ------------ |
            // | . | .yield_return | <- 1b. place this frame now
            // | - | ------------ |
            // | . |  GENERATOR   | <- 1a. yield; 3. resume here, continue generating
            // | - | ------------ |
            // | . | .call        |
            // | - | ------------ |
            // | . |      ...     |
            // | - | ------------ |
            //
            // This concludes a rough sketch demonstrating this strategy
            // achieves the desired semantics.
            .call => |call| {
                const caller_env = self.stack.items[idx - 1].state.environment;
                const continuation_env = try self.envCopy(caller_env);

                try self.pushFrame(Frame{
                    .state = State{
                        .pc = call.resume_address,
                        .value = value.clone(),
                        .environment = continuation_env,
                    },
                    .boundary = Boundary{ .yield_return = .{ .boundary_idx = idx } },
                });
            },
            .alt => |alt| {
                const caller_env = self.stack.items[idx - 1].state.environment;
                const continuation_env = try self.envCopy(caller_env);

                try self.pushFrame(Frame{
                    .state = State{
                        .pc = alt.resume_address,
                        .value = value.clone(),
                        .environment = continuation_env,
                    },
                    .boundary = Boundary{ .yield_return = .{ .boundary_idx = idx } },
                });
            },
            else => unreachable,
        }
        return true;
    }

    fn getSource(self: *Self, state: State, vs: ValueSource) !rt.Value {
        return switch (vs) {
            .literal => |v| switch (v) {
                .nothing => .nothing,
                .bool => |b| rt.Value{ .bool = b },
                .int => |i| rt.Value{ .int = i },
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
                .length => switch (state.value) {
                    .string => |s| rt.Value{ .int = @intCast(s.len) },
                    else => error.UnexpectedType,
                },
            },
            .variable_id => |v| self.envGet(state.environment, v) orelse rt.Value{ .nothing = {} },
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
                    const env_copy_new_frame = try self.envCopy(frame.state.environment);

                    try self.pushFrame(Frame{
                        .state = State{
                            .pc = split.resume_pc,
                            .value = split.iterator.value(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = .passthrough,
                    });
                } else {
                    try self.handleBranchEnd();
                }
                continue;
            }

            self.profile.countInstruction();
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
                                if (value == .nothing) null else value.clone(),
                            ) };
                        },
                        .elements => |vs| blk: {
                            const value = try self.getSource(frame.state, vs);
                            break :blk switch (value) {
                                .list => |l| .{ .list = ListIterator{ .list = l.reference() } },
                                .nothing => .{ .singleton = SingletonIterator.init(null) },
                                else => return error.UnexpectedType,
                            };
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
                            const new_environment = try self.envPut(
                                old_env,
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
                            .int => |a_int| switch (b_value) {
                                .int => |b_int| a_int < b_int,
                                else => error.InvalidArguments,
                            },
                            else => error.InvalidArguments,
                        },
                        .gt => switch (a_value) {
                            .int => |a_int| switch (b_value) {
                                .int => |b_int| a_int > b_int,
                                else => error.InvalidArguments,
                            },
                            else => error.InvalidArguments,
                        },
                    };
                    const result = rt.Value{ .bool = relates };
                    if (x.dest) |var_id| {
                        const old_env = frame.state.environment;
                        const new_env = try self.envPut(old_env, var_id, result);
                        frame.state.environment = new_env;
                        old_env.dereference(self.allocator);
                    } else {
                        frame.state.value.deinit(self.allocator);
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
                    const env_copy_old_frame = try self.envCopy(old_env);
                    const env_copy_new_frame = try self.envCopy(old_env);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    const boundary = switch (probe_inst.data) {
                        .exists => Boundary{ .exists = .{
                            .resume_address = probe_inst.resume_address,
                        } },
                        .nexists => Boundary{ .nexists = .{
                            .resume_address = probe_inst.resume_address,
                        } },
                        .aggregate => |spec| switch (spec.kind) {
                            .list => Boundary{
                                .aggregate = .{
                                    .resume_address = probe_inst.resume_address,
                                    .variable = spec.variable,
                                    .value = .{
                                        .list = try ds.Rc(List).create(self.allocator, List.init()),
                                    },
                                },
                            },
                            .record => Boundary{
                                .aggregate = .{
                                    .resume_address = probe_inst.resume_address,
                                    .variable = spec.variable,
                                    .value = .{
                                        .record = .{
                                            .rc = try ds.Rc(Record).create(self.allocator, Record.init(self.allocator)),
                                        },
                                    },
                                },
                            },
                        },
                    };

                    try self.pushFrame(Frame{
                        .state = State{
                            .pc = frame.state.pc,
                            .value = frame.state.value.clone(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = boundary,
                    });
                },
                .call => |target_address| {
                    frame.state.pc += 1;
                    const resume_address = frame.state.pc;

                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try self.envCopy(old_env);
                    const env_copy_new_frame = try self.envCopy(old_env);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    try self.pushFrame(Frame{
                        .state = State{
                            .pc = target_address,
                            .value = frame.state.value.clone(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = Boundary{ .call = .{ .resume_address = resume_address } },
                    });
                },
                .make_closure => |mc| {
                    frame.state.pc += 1;

                    self.profile.countClosure();
                    const closure = try ds.Rc(rt.Closure).create(self.allocator, .{
                        .entry = mc.entry,
                        .arity = mc.arity,
                        .param_vars_offset = mc.param_vars_offset,
                        .applied = &.{},
                        .captured_env = frame.state.environment.reference(),
                    });

                    const value = rt.Value{ .closure = closure };
                    const old_env = frame.state.environment;
                    const new_env = try self.envPut(old_env, mc.dest, value);
                    frame.state.environment = new_env;
                    old_env.dereference(self.allocator);
                },
                .apply => |ap| {
                    frame.state.pc += 1;

                    const closure_value = try self.getSource(frame.state, ap.closure);
                    const closure = switch (closure_value) {
                        .closure => |c| c,
                        else => return error.UnexpectedType,
                    };
                    const arg_value = try self.getSource(frame.state, ap.argument);

                    const new_applied_len = closure.value.applied.len + 1;
                    if (new_applied_len < closure.value.arity) {
                        const new_applied = try self.allocator.alloc(rt.Value, new_applied_len);
                        for (closure.value.applied, 0..) |v, i| new_applied[i] = v.clone();
                        new_applied[new_applied_len - 1] = arg_value.clone();

                        self.profile.countClosure();
                        const new_closure = try ds.Rc(rt.Closure).create(self.allocator, .{
                            .entry = closure.value.entry,
                            .arity = closure.value.arity,
                            .param_vars_offset = closure.value.param_vars_offset,
                            .applied = new_applied,
                            .captured_env = closure.value.captured_env.reference(),
                        });

                        var old_value = frame.state.value;
                        frame.state.value = rt.Value{ .closure = new_closure };
                        old_value.deinit(self.allocator);
                    } else {
                        const resume_address = frame.state.pc;

                        var call_env = closure.value.captured_env.reference();
                        for (closure.value.applied, 0..) |v, i| {
                            const param_var = self.param_var_arena[closure.value.param_vars_offset + i];
                            // IMPROVE: Is there a way we can avoid this allocation?
                            // It may take completely changing how `make_closure` and `apply` works
                            const next_env = try self.envPut(call_env, param_var, v.clone());
                            call_env.dereference(self.allocator);
                            call_env = next_env;
                        }
                        const final_param_var = self.param_var_arena[closure.value.param_vars_offset + closure.value.applied.len];
                        const final_env = try self.envPut(call_env, final_param_var, arg_value.clone());
                        call_env.dereference(self.allocator);

                        const old_env = frame.state.environment;
                        const env_copy_old_frame = try self.envCopy(old_env);
                        frame.state.environment = env_copy_old_frame;
                        old_env.dereference(self.allocator);

                        try self.pushFrame(Frame{
                            .state = State{
                                .pc = closure.value.entry,
                                .value = frame.state.value.clone(),
                                .environment = final_env,
                            },
                            .boundary = Boundary{ .call = .{ .resume_address = resume_address } },
                        });
                    }
                },
                .alt => |alt_inst| {
                    frame.state.pc += 1;
                    const resume_address = frame.state.pc;

                    const old_env = frame.state.environment;
                    const env_copy_old_frame = try self.envCopy(old_env);
                    const env_copy_new_frame = try self.envCopy(old_env);
                    frame.state.environment = env_copy_old_frame;
                    old_env.dereference(self.allocator);

                    try self.pushFrame(Frame{
                        .state = State{
                            .pc = alt_inst.left_entry,
                            .value = frame.state.value.clone(),
                            .environment = env_copy_new_frame,
                        },
                        .boundary = Boundary{ .alt = .{
                            .resume_address = resume_address,
                            .right_entry = alt_inst.right_entry,
                            .phase = .left,
                        } },
                    });
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
