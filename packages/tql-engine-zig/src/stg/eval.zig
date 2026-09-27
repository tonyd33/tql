//! Graph reduction over the STG-shaped term language: force a thunk by running
//! its body, memoize the result, dispatch a `case` on the scrutinee's tag.
//!
//! Calls are eval/apply. The caller reads the callee's arity and decides
//! whether the call is saturated, over-applied, or partial.
//!
//! Everything allocates in one arena owned by the Machine and freed with it.
//! Nothing is collected during a run.

const std = @import("std");
const ts = @import("tree-sitter");
const pcre2 = @import("../regex.zig");
const primitives = @import("../primitives.zig");
const stg = @import("terms.zig");
const core = @import("../core.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

/// Allocation counters, by call site. Profiling only.
pub const Site = enum {
    global_thunk,
    force_literal,
    run_env,
    pending_append,
    enter_captures,
    let_thunk,
    let_binder,
    case_binder,
    apply_args,
    primitive_args,
    record_fields,
    toint_thunk,
    filename_thunk,
    construct_spill,
    node_thunk,
    nil_thunk,
    cons_thunk,
    step_tail,
    alloc_captured,
    apply_partial,
    apply_all,
};
/// Shared by every machine, so every worker thread writes them.
pub var site_counts: std.EnumArray(Site, std.atomic.Value(u64)) = .initFill(.init(0));
pub var site_bytes: std.EnumArray(Site, std.atomic.Value(u64)) = .initFill(.init(0));

/// Counting every allocation costs about 4x on a release build, so it is off
/// unless a profiling run turns it on.
pub const count_allocations = false;

inline fn note(site: Site, bytes: usize) void {
    if (!count_allocations) return;
    _ = site_counts.getPtr(site).fetchAdd(1, .monotonic);
    _ = site_bytes.getPtr(site).fetchAdd(bytes, .monotonic);
}

pub const Error = Allocator.Error || std.Io.Writer.Error || error{
    /// A thunk was re-entered while it was still being evaluated.
    Cycle,
    /// Division or modulo by zero.
    DivideByZero,
    /// Reached only by a program the type checker should have rejected.
    TypeError,
    /// Evaluation nested deeper than the machine's stack budget.
    StackOverflow,
    /// A local read a slot bound under a different name. Reached only by a
    /// translation bug, and checked only in safe builds.
    MisplacedLocal,
};

/// Whether each environment slot records the name it was bound under, and
/// every local read checks it.
const check_locals = std.debug.runtime_safety;

/// The slots a body reads by offset.
const Env = struct {
    thunks: std.ArrayList(*value.Thunk) = .empty,
    names: if (check_locals) std.ArrayList(core.SymbolId) else void =
        if (check_locals) .empty else {},

    fn slots(self: *const Env) Slots {
        return .{
            .thunks = self.thunks.items,
            .names = if (check_locals) self.names.items else {},
        };
    }

    fn len(self: *const Env) usize {
        return self.thunks.items.len;
    }

    fn shrink(self: *Env, n: usize) void {
        self.thunks.shrinkRetainingCapacity(n);
        if (check_locals) self.names.shrinkRetainingCapacity(n);
    }

    fn ensureTotalCapacity(self: *Env, gpa: Allocator, n: usize) Allocator.Error!void {
        try self.thunks.ensureTotalCapacity(gpa, n);
        if (check_locals) try self.names.ensureTotalCapacity(gpa, n);
    }

    fn append(self: *Env, gpa: Allocator, thunk: *value.Thunk, name: core.SymbolId) Allocator.Error!void {
        try self.thunks.append(gpa, thunk);
        if (check_locals) try self.names.append(gpa, name);
    }

    /// Append `thunks`, bound under `names` in order.
    fn appendSlice(
        self: *Env,
        gpa: Allocator,
        thunks: []const *value.Thunk,
        names: []const core.SymbolId,
    ) Allocator.Error!void {
        try self.thunks.appendSlice(gpa, thunks);
        if (check_locals) try self.names.appendSlice(gpa, names);
    }

    /// Append `thunks`, bound under `names` in order, into capacity already
    /// reserved.
    fn appendSliceAssumeCapacity(
        self: *Env,
        thunks: []const *value.Thunk,
        names: []const core.SymbolId,
    ) void {
        self.thunks.appendSliceAssumeCapacity(thunks);
        if (check_locals) self.names.appendSliceAssumeCapacity(names);
    }

    /// Append what a closure captured, bound under its free variables' names,
    /// into capacity already reserved.
    fn appendCapturesAssumeCapacity(
        self: *Env,
        captured: []const *value.Thunk,
        code: *const stg.Closure,
    ) Error!void {
        self.thunks.appendSliceAssumeCapacity(captured);
        if (check_locals) {
            if (captured.len != code.free.len) return error.MisplacedLocal;
            for (code.free) |local| self.names.appendAssumeCapacity(local.name);
        }
    }

    fn deinit(self: *Env, gpa: Allocator) void {
        self.thunks.deinit(gpa);
        if (check_locals) self.names.deinit(gpa);
    }
};

/// A read-only view of an environment's slots.
const Slots = struct {
    thunks: []const *value.Thunk,
    names: if (check_locals) []const core.SymbolId else void,

    fn prefix(self: Slots, n: usize) Slots {
        return .{
            .thunks = self.thunks[0..n],
            .names = if (check_locals) self.names[0..n] else {},
        };
    }

    fn get(self: Slots, local: stg.Local) Error!*value.Thunk {
        if (local.offset >= self.thunks.len) return error.TypeError;
        if (check_locals) {
            if (self.names[local.offset] != local.name) return error.MisplacedLocal;
        }
        return self.thunks[local.offset];
    }
};

pub const Machine = struct {
    arena: Allocator,
    program: *const stg.Program,
    /// One thunk per global, in `program.definitions` order, allocated before
    /// the run and forced at most once.
    globals: []value.Thunk,
    /// Scratch for every regex test this run makes, created on the first.
    match_data: ?pcre2.MatchData = null,
    /// The file being queried. Absent when the machine runs hand-built terms,
    /// in which case every tree primitive is a type error rather than a
    /// wrong answer.
    target: ?Target = null,

    /// Every cursor handed to a traversal. A suspended walk has no moment at
    /// which it is known finished, so the machine owns them and frees them all
    /// when the run ends.
    ///
    /// A cursor holds a heap-allocated stack, so it cannot live in the arena.
    cursors: std.ArrayList(*ts.TreeCursor) = .empty,
    /// Cursors whose walk ran out, ready to be reset onto a new node. Each is
    /// also in `cursors`.
    spare_cursors: std.ArrayList(*ts.TreeCursor) = .empty,
    gpa: Allocator,

    /// Environment buffers lent to `expression` and returned on exit.
    ///
    /// Each activation needs two, and a `case` scrutinee is the only thing
    /// that nests, so the pool is as deep as a term nests rather than as long
    /// as a list. Reusing them is what keeps a saturated call from growing a
    /// fresh array: the capacity from the last call is already there.
    env_pool: std.ArrayList(Env) = .empty,

    /// Argument slices for calls in flight, as one stack.
    ///
    /// A callee reads its arguments and copies out whatever it keeps, so a
    /// slice dies when the call returns. Handing them out of a stack that
    /// unwinds with the call replaces one arena allocation per call, which is
    /// the single largest source of them.
    args: std.ArrayList(*value.Thunk) = .empty,

    /// What each `expression` activation owes once its loop produces a value,
    /// as one stack. An activation owns the entries above the mark it took on
    /// entry, and pops them in order.
    frames: std.ArrayList(Frame) = .empty,

    /// The arguments an `apply` frame is still to supply, as one stack in
    /// frame order.
    held: std.ArrayList(*value.Thunk) = .empty,

    /// `@frameAddress` where the machine was built, or 0 where the target has
    /// none to give.
    stack_base: usize,
    /// How far below `stack_base` evaluation may nest before it stops with
    /// error.StackOverflow instead of overrunning the thread's stack.
    stack_budget: usize = default_stack_budget,

    /// Fits the 8 MiB stack a main thread usually gets. A machine run on a
    /// smaller stack needs a smaller budget.
    pub const default_stack_budget = 6 * 1024 * 1024;

    const Frame = union(enum) {
        /// Overwrite this entered thunk with the value.
        update: *value.Thunk,
        /// Apply the value to this many thunks off the top of `held`.
        apply: usize,
    };

    /// The queried file: what `text` slices, and what `filename` yields.
    pub const Target = struct {
        source: []const u8,
        path: ?[]const u8,
    };

    pub fn init(
        arena: Allocator,
        gpa: Allocator,
        program: *const stg.Program,
    ) Allocator.Error!Machine {
        // Every global is allocated before any is filled, so one may reference
        // another in any order.
        const globals = try arena.alloc(value.Thunk, program.definitions.len);
        for (program.definitions, globals) |definition, *thunk| {
            thunk.* = .{ .state = .{ .unevaluated = .{
                .code = definition.value,
                .captured = &.{},
            } } };
        }

        return .{
            .arena = arena,
            .program = program,
            .globals = globals,
            .gpa = gpa,
            .stack_base = @frameAddress(),
        };
    }

    pub fn deinit(self: *Machine) void {
        const gpa = self.gpa;
        if (self.match_data) |*m| m.deinit();
        for (self.cursors.items) |c| {
            c.destroy();
            gpa.destroy(c);
        }
        self.cursors.deinit(gpa);
        self.spare_cursors.deinit(gpa);
        for (self.env_pool.items) |*e| e.deinit(gpa);
        self.env_pool.deinit(gpa);
        self.args.deinit(gpa);
        self.frames.deinit(gpa);
        self.held.deinit(gpa);
    }

    /// Stop with error.StackOverflow once evaluation has nested past the
    /// budget. Called by everything that recurses.
    fn checkStack(self: *const Machine) Error!void {
        if (self.stack_base == 0) return;
        if (self.stack_base -| @frameAddress() > self.stack_budget) return error.StackOverflow;
    }

    /// Borrow an empty environment buffer, keeping whatever capacity it has.
    fn takeEnv(self: *Machine) Error!Env {
        if (self.env_pool.pop()) |buffer| {
            var reused = buffer;
            reused.shrink(0);
            return reused;
        }
        return .{};
    }

    /// Resolve `atoms` onto the argument stack and return them as a slice.
    ///
    /// Valid until the caller truncates the stack back to the mark it took
    /// before calling. The slice must not be retained: growing the stack for
    /// a nested call can move it.
    fn pushArgs(self: *Machine, atoms: []const stg.Atom, env: Slots) Error![]const *value.Thunk {
        const base = self.args.items.len;
        try self.args.ensureUnusedCapacity(self.gpa, atoms.len);
        for (atoms) |atom| {
            self.args.appendAssumeCapacity(try self.resolve(env, atom));
        }
        return self.args.items[base..];
    }

    fn giveEnv(self: *Machine, buffer: Env) void {
        self.env_pool.append(self.gpa, buffer) catch {
            var owned = buffer;
            owned.deinit(self.gpa);
        };
    }

    /// A cursor positioned on `n`, owned by the machine. Reuses a spare one
    /// when there is one.
    fn newCursor(self: *Machine, n: ts.Node) Error!*ts.TreeCursor {
        if (self.spare_cursors.pop()) |cursor| {
            cursor.reset(n);
            return cursor;
        }
        const cursor = try self.gpa.create(ts.TreeCursor);
        errdefer self.gpa.destroy(cursor);
        cursor.* = n.walk();
        errdefer cursor.destroy();
        try self.cursors.append(self.gpa, cursor);
        return cursor;
    }

    /// Make the cursor of a walk that ran out available to the next one.
    ///
    /// Preconditions:
    /// - nothing reads `cursor` again until `newCursor` hands it out
    fn releaseCursor(self: *Machine, cursor: *ts.TreeCursor) void {
        // Left in `cursors` if this fails, so it is still freed with the run.
        self.spare_cursors.append(self.gpa, cursor) catch {};
    }

    /// Read an atom without forcing it.
    fn resolve(self: *Machine, env: Slots, atom: stg.Atom) Error!*value.Thunk {
        return switch (atom) {
            // The translator numbered every reference against the environment
            // this builds, so a local is an index rather than a search.
            .local => |local| try env.get(local),
            .global => |g| &self.globals[g.index],
            .literal => |thunk| thunk,
        };
    }

    /// The thunk of the top-level definition `symbol`, if there is one.
    pub fn global(self: *const Machine, symbol: core.SymbolId) ?*value.Thunk {
        for (self.program.definitions, self.globals) |definition, *thunk| {
            if (definition.symbol == symbol) return thunk;
        }
        return null;
    }

    /// Force a thunk to a value and memoize it. A closure of one or more
    /// parameters is already a value; only a thunk of none runs its body.
    ///
    /// Returns error.Cycle if the thunk is already being evaluated.
    pub fn force(self: *Machine, thunk: *value.Thunk) Error!value.Value {
        switch (thunk.state) {
            .evaluated => |v| return v,
            .evaluating => return error.Cycle,
            // A suspended axis steps the walk rather than running a term.
            .traversing => |t| {
                const result = try self.step(t);
                thunk.fill(result);
                return result;
            },
            // By value, so `enter` overwriting the union below does not
            // invalidate it.
            .unevaluated => |pending| {
                if (!thunk.enter()) return error.Cycle;

                if (pending.code.parameters.len > 0) {
                    const v: value.Value = .{ .closure = .{
                        .code = pending.code,
                        .captured = pending.captured,
                    } };
                    thunk.fill(v);
                    return v;
                }

                const result = try self.run(pending.code, pending.captured, &.{});
                thunk.fill(result);
                return result;
            },
        }
    }

    /// Run a closure body in an environment of its captures and arguments.
    fn run(
        self: *Machine,
        code: *const stg.Closure,
        captured: []const *value.Thunk,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != code.parameters.len) return error.TypeError;

        var env = try self.takeEnv();
        defer self.giveEnv(env);

        note(.run_env, (captured.len + code.parameters.len) * @sizeOf(*value.Thunk));
        try env.ensureTotalCapacity(self.gpa, captured.len + arguments.len);
        try env.appendCapturesAssumeCapacity(captured, code);
        env.appendSliceAssumeCapacity(arguments, code.parameters);

        return try self.expression(code.body, &env);
    }

    /// Evaluate a term to WHNF.
    ///
    /// Tail positions loop rather than recurse: `let` and `case` bodies, and
    /// a call's body, all become the next term this loop runs. An
    /// over-applied call enters its callee here too, and leaves an `apply`
    /// frame to supply the rest once the body produces a function. The native
    /// stack then grows with a term's nesting rather than with the length of
    /// a list a filter chain walks.
    ///
    /// A `case` scrutinee is the one sub-term evaluated by recursion, and it
    /// is what bounds the depth.
    fn expression(
        self: *Machine,
        expr: stg.Expr,
        env: *Env,
    ) Error!value.Value {
        try self.checkStack();

        // Rebound whenever a call enters a body, which runs in the callee's
        // own environment rather than the caller's.
        var current = expr;
        var scope = env;

        // Two buffers, used alternately: building the callee's environment
        // reads the current one, so it cannot write into it. Borrowed from the
        // machine so their capacity survives the call.
        var envs: [2]Env = .{ try self.takeEnv(), try self.takeEnv() };
        defer for (envs) |e| self.giveEnv(e);
        var next: usize = 0;

        const frames_base = self.frames.items.len;
        const held_base = self.held.items.len;
        defer {
            self.frames.shrinkRetainingCapacity(frames_base);
            self.held.shrinkRetainingCapacity(held_base);
        }

        while (true) {
            var produced: value.Value = switch (current) {
                // Forcing the named thunk is itself a tail position. An
                // unevaluated nullary one continues in this loop, under an
                // `update` frame that overwrites it with what the loop
                // produces.
                .atom => |atom| blk: {
                    const thunk = try self.resolve(scope.slots(), atom);
                    switch (thunk.state) {
                        .evaluated => |v| break :blk v,
                        .evaluating => return error.Cycle,
                        .traversing => |t| {
                            const stepped = try self.step(t);
                            thunk.fill(stepped);
                            break :blk stepped;
                        },
                        .unevaluated => |suspended| {
                            if (suspended.code.parameters.len > 0) {
                                if (!thunk.enter()) return error.Cycle;
                                const v: value.Value = .{ .closure = .{
                                    .code = suspended.code,
                                    .captured = suspended.captured,
                                } };
                                thunk.fill(v);
                                break :blk v;
                            }
                            if (!thunk.enter()) return error.Cycle;
                            try self.frames.append(self.gpa, .{ .update = thunk });

                            const target = &envs[next];
                            target.shrink(0);
                            try target.ensureTotalCapacity(self.gpa, suspended.captured.len);
                            try target.appendCapturesAssumeCapacity(suspended.captured, suspended.code);
                            current = suspended.code.body;
                            scope = target;
                            next = 1 - next;
                            continue;
                        },
                    }
                },

                .constructed => |constructed| .{ .constructed = try self.construct(
                    constructed.constructor,
                    constructed.tag,
                    constructed.fields,
                    scope.slots(),
                ) },

                .let => |let| {
                    const base = scope.len();
                    for (let.bindings) |binding| {
                        note(.let_thunk, @sizeOf(value.Thunk));
                        const thunk = try self.arena.create(value.Thunk);
                        try scope.append(self.gpa, thunk, binding.binder);
                    }

                    // A recursive group is filled against the environment
                    // holding all of its own binders, so a binding may
                    // reference one that comes later. A non-recursive one is
                    // filled against the environment as it stood before the
                    // group, so a binding sees only what was already in scope.
                    const slots = scope.slots();
                    const inner = if (let.recursive) slots else slots.prefix(base);
                    for (let.bindings, base..) |binding, i| {
                        try self.fillAllocation(slots.thunks[i], binding.value, inner);
                    }
                    current = let.body;
                    continue;
                },

                .case => |case_expr| {
                    // The scrutinee runs in this environment and may push its
                    // own binders onto it. The alternative's binders are
                    // numbered from where the scrutinee started, so those are
                    // dropped first.
                    const mark = scope.len();
                    const scrutinee = try self.expression(case_expr.scrutinee, scope);
                    scope.shrink(mark);
                    const constructed = switch (scrutinee) {
                        .constructed => |c| c,
                        else => return error.TypeError,
                    };

                    // Alternatives are in tag order and cover every
                    // constructor, so the tag is the index.
                    if (constructed.tag >= case_expr.alternatives.len) return error.TypeError;
                    const alternative = case_expr.alternatives[constructed.tag];
                    if (alternative.binders.len != constructed.len) return error.TypeError;

                    // The binders stay in scope for the body, which this loop
                    // runs next. Dropping them afterwards is what the
                    // recursive form did; binders are globally unique, so
                    // leaving them costs space and shadows nothing.
                    //
                    // Read through the local copy: inline fields live in the
                    // value itself, so a slice of it must not outlive this
                    // scope.
                    note(.case_binder, alternative.binders.len * @sizeOf(*value.Thunk));
                    try scope.appendSlice(self.gpa, constructed.fields(), alternative.binders);
                    current = alternative.body;
                    continue;
                },

                .apply => |call| blk: {
                    const callee = try self.force(try self.resolve(scope.slots(), call.callee));

                    // The arguments die with the call, so they come off the
                    // stack rather than the arena. Truncated before the loop
                    // continues, so a chain of tail calls does not grow it.
                    const mark = self.args.items.len;
                    defer self.args.shrinkRetainingCapacity(mark);
                    const arguments = try self.pushArgs(call.arguments, scope.slots());

                    const target = &envs[next];
                    switch (try self.invoke(callee, arguments, target)) {
                        .value => |v| break :blk v,
                        .entered => |body| {
                            current = body;
                            scope = target;
                            next = 1 - next;
                            continue;
                        },
                    }
                },

                .primitive => |call| blk: {
                    // Not on the argument stack: a primitive forces one
                    // argument before reading the next, and forcing can grow
                    // and move it.
                    var inline_arguments: [4]*value.Thunk = undefined;
                    const arguments = if (call.arguments.len <= inline_arguments.len)
                        inline_arguments[0..call.arguments.len]
                    else
                        try self.arena.alloc(*value.Thunk, call.arguments.len);
                    const slots = scope.slots();
                    for (call.arguments, arguments) |atom, *argument| {
                        argument.* = try self.resolve(slots, atom);
                    }
                    break :blk try self.primitive(call, arguments);
                },
            };

            // Settle what this loop owes, innermost first. An `apply` frame
            // may enter a body, which this loop then runs.
            while (self.frames.items.len > frames_base) {
                switch (self.frames.pop().?) {
                    .update => |thunk| thunk.fill(produced),
                    .apply => |count| {
                        const start = self.held.items.len - count;
                        const target = &envs[next];
                        switch (try self.invokeHeld(produced, start, target)) {
                            .value => |v| produced = v,
                            .entered => |body| {
                                current = body;
                                scope = target;
                                next = 1 - next;
                                break;
                            },
                        }
                    },
                }
            } else return produced;
        }
    }

    const Invoked = union(enum) {
        /// A partial application, already a value.
        value: value.Value,
        /// The callee's body, to run in the environment `invoke` filled.
        entered: stg.Expr,
    };

    /// Call `callee` with `arguments`, for `expression`'s loop to continue.
    ///
    /// Saturated, it fills `out` with the callee's environment and returns the
    /// body. Over-applied, it does the same with as many arguments as the
    /// callee takes, and pushes an `apply` frame holding the rest. Partial, it
    /// returns the closure with the arguments kept on it.
    ///
    /// Preconditions:
    /// - `arguments` is not a slice of `held`
    fn invoke(
        self: *Machine,
        callee: value.Value,
        arguments: []const *value.Thunk,
        out: *Env,
    ) Error!Invoked {
        const closure = switch (callee) {
            .closure => |c| c,
            else => return error.TypeError,
        };
        const needed = closure.code.parameters.len - closure.applied.len;
        if (arguments.len < needed) return .{ .value = try self.partial(closure, arguments) };

        if (arguments.len > needed) {
            try self.held.appendSlice(self.gpa, arguments[needed..]);
            try self.frames.append(self.gpa, .{ .apply = arguments.len - needed });
        }
        return .{ .entered = try self.enter(closure, arguments[0..needed], out) };
    }

    /// `invoke`, for the arguments of an `apply` frame just popped: those on
    /// `held` from `start` to its top.
    ///
    /// Leaves `held` truncated to `start`, plus whatever a further `apply`
    /// frame still holds.
    fn invokeHeld(
        self: *Machine,
        callee: value.Value,
        start: usize,
        out: *Env,
    ) Error!Invoked {
        const closure = switch (callee) {
            .closure => |c| c,
            else => return error.TypeError,
        };
        const arguments = self.held.items[start..];
        const needed = closure.code.parameters.len - closure.applied.len;
        if (arguments.len < needed) {
            const v = try self.partial(closure, arguments);
            self.held.shrinkRetainingCapacity(start);
            return .{ .value = v };
        }

        const body = try self.enter(closure, arguments[0..needed], out);
        const rest = arguments.len - needed;
        if (rest > 0) {
            // The rest are already on `held`. Moved down over the ones just
            // consumed, they become the next frame's without reallocating.
            std.mem.copyForwards(*value.Thunk, self.held.items[start..], arguments[needed..]);
            try self.frames.append(self.gpa, .{ .apply = rest });
        }
        self.held.shrinkRetainingCapacity(start + rest);
        return .{ .entered = body };
    }

    /// A closure with `arguments` kept on it after the ones it already had.
    fn partial(self: *Machine, closure: value.Closure, arguments: []const *value.Thunk) Error!value.Value {
        const supplied = closure.applied.len + arguments.len;
        note(.apply_partial, supplied * @sizeOf(*value.Thunk));
        const applied = try self.arena.alloc(*value.Thunk, supplied);
        @memcpy(applied[0..closure.applied.len], closure.applied);
        @memcpy(applied[closure.applied.len..], arguments);
        return .{ .closure = .{
            .code = closure.code,
            .captured = closure.captured,
            .applied = applied,
        } };
    }

    /// Fill `out` with a saturated call's environment and return the body to
    /// run.
    ///
    /// Preconditions:
    /// - `arguments` supplies exactly the parameters `closure` still lacks
    fn enter(
        self: *Machine,
        closure: value.Closure,
        arguments: []const *value.Thunk,
        out: *Env,
    ) Error!stg.Expr {
        const parameters = closure.code.parameters;
        if (closure.applied.len + arguments.len != parameters.len) return error.TypeError;

        out.shrink(0);
        note(.enter_captures, (closure.captured.len + closure.code.parameters.len) * @sizeOf(*value.Thunk));
        // Sized once: three appends onto a buffer whose capacity is already
        // known re-check it three times otherwise, and this is the hottest
        // path in the machine.
        try out.ensureTotalCapacity(
            self.gpa,
            closure.captured.len + closure.applied.len + arguments.len,
        );
        try out.appendCapturesAssumeCapacity(closure.captured, closure.code);
        // Arguments in parameter order: what a partial application already
        // supplied, then what this call brought.
        const split = closure.applied.len;
        out.appendSliceAssumeCapacity(closure.applied, parameters[0..split]);
        out.appendSliceAssumeCapacity(arguments, parameters[split..]);
        return closure.code.body;
    }

    /// Run a primitive, forcing exactly what its denotation forces and no
    /// more. `pure` forces nothing, `probe` forces at most the first result,
    /// `length` forces a whole spine.
    fn primitive(
        self: *Machine,
        call: *const stg.Expr.Primitive,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        switch (call.primop) {
            // `length` forces the spine, so it diverges on an infinite list.
            .length => {
                if (arguments.len != 1) return error.TypeError;
                const subject = try self.force(arguments[0]);
                return switch (subject) {
                    .string => |s| .{ .number = @intCast(s.len) },
                    .constructed => blk: {
                        var count: i64 = 0;
                        var current = subject;
                        while (true) {
                            const c = switch (current) {
                                .constructed => |k| k,
                                else => return error.TypeError,
                            };
                            if (c.tag == self.program.structural.nil.tag) break;
                            if (c.len != 2) return error.TypeError;
                            count += 1;
                            current = try self.force(c.fields()[1]);
                        }
                        break :blk .{ .number = count };
                    },
                    else => error.TypeError,
                };
            },

            .operator => return try self.operator(call, arguments),

            // Fields are scalars and stay unforced. The labels come from the
            // symbol's details, already sorted.
            .record => {
                const labels = switch (try synthesized(call)) {
                    .record => |l| l,
                    else => return error.TypeError,
                };
                if (labels.len != arguments.len) return error.TypeError;

                const fields = try self.arena.alloc(value.Field, labels.len);
                for (labels, arguments, fields) |label, thunk, *field| {
                    field.* = .{ .label = label, .thunk = thunk };
                }
                return .{ .record = fields };
            },

            // Total functions on a node: every node has one, so each returns
            // a scalar rather than a singleton list.
            .text => {
                const subject = try self.nodeArgument(arguments);
                const target = self.target orelse return error.TypeError;
                return .{ .string = target.source[subject.startByte()..subject.endByte()] };
            },
            .kind => {
                const subject = try self.nodeArgument(arguments);
                return .{ .string = subject.kind() };
            },
            .range => {
                const subject = try self.nodeArgument(arguments);
                return .{ .range = rangeOf(subject) };
            },

            // `[x]` when the static kind matches, otherwise `[]`.
            .is_kind => {
                const subject = try self.nodeArgument(arguments);
                const wanted = switch (try synthesized(call)) {
                    .kind_test => |k| k.id,
                    else => return error.TypeError,
                };
                if (subject.kindId() != wanted) return self.nil();
                return self.singleton(arguments[0]);
            },

            // `[parent]`, or `[]` at the root.
            .parent => {
                const subject = try self.nodeArgument(arguments);
                const up = subject.parent() orelse return self.nil();
                return self.singleton(try self.nodeThunk(up));
            },

            // Proper ancestors, nearest first. Bounded by tree depth, so it
            // is built eagerly.
            .ancestors => {
                const subject = try self.nodeArgument(arguments);
                var list = try self.nilThunk();
                var chain: std.ArrayList(ts.Node) = .empty;
                defer chain.deinit(self.arena);

                var current = subject;
                while (current.parent()) |up| : (current = up) {
                    try chain.append(self.arena, up);
                }

                // Built from the far end back, so the nearest ancestor ends
                // up at the head.
                var i = chain.items.len;
                while (i > 0) {
                    i -= 1;
                    list = try self.consThunk(try self.nodeThunk(chain.items[i]), list);
                }
                return try self.force(list);
            },

            .toint => {
                if (arguments.len != 1) return error.TypeError;
                const subject = try self.force(arguments[0]);
                const text = switch (subject) {
                    .string => |s| s,
                    else => return error.TypeError,
                };
                const parsed = parseInt(text) orelse return self.nil();
                const thunk = try self.arena.create(value.Thunk);
                thunk.* = value.Thunk.value(.{ .number = parsed });
                return self.singleton(thunk);
            },

            // Constant across the query, and it never reads its argument.
            .filename => {
                const target = self.target orelse return self.nil();
                const path = target.path orelse return self.nil();
                const thunk = try self.arena.create(value.Thunk);
                thunk.* = value.Thunk.value(.{ .string = path });
                return self.singleton(thunk);
            },

            // Named children, document order.
            .children => {
                const subject = try self.nodeArgument(arguments);
                const cursor = try self.newCursor(subject);
                return try self.step(.{
                    .cursor = cursor,
                    .live = descendToNamedChild(cursor),
                    .axis = .children,
                });
            },

            // Named proper descendants, pre-order. Proper: the walk starts by
            // stepping off the subject, so a node is not its own descendant.
            .descendants => {
                const subject = try self.nodeArgument(arguments);
                const cursor = try self.newCursor(subject);
                return try self.step(.{
                    .cursor = cursor,
                    .live = advanceDescendant(cursor),
                    .axis = .descendants,
                });
            },

            // Named children under one field, document order. A field the
            // grammar knows but this node lacks yields no output.
            .field => {
                const subject = try self.nodeArgument(arguments);
                const field_id = switch (try synthesized(call)) {
                    .field => |f| f.id,
                    else => return error.TypeError,
                };
                const cursor = try self.newCursor(subject);
                return try self.step(.{
                    .cursor = cursor,
                    .live = descendToFieldChild(cursor, field_id),
                    .axis = .field,
                    .field_id = field_id,
                });
            },

            // The `children`/`descendants` walks with the kind test folded
            // into the advance, so the list holds only matches.
            .children_of_kind, .descendants_of_kind => {
                const subject = try self.nodeArgument(arguments);
                const kind_id = switch (try synthesized(call)) {
                    .kind_axis => |k| k.id,
                    else => return error.TypeError,
                };
                const descendants = call.primop == .descendants_of_kind;
                const cursor = try self.newCursor(subject);
                return try self.step(.{
                    .cursor = cursor,
                    .live = if (descendants)
                        advanceDescendantOfKind(cursor, kind_id)
                    else
                        descendToChildOfKind(cursor, kind_id),
                    .axis = if (descendants) .descendants_of_kind else .children_of_kind,
                    .kind_id = kind_id,
                });
            },
        }
    }

    /// What a synthesized primitive denotes.
    fn synthesized(call: *const stg.Expr.Primitive) Error!core.Synthesized {
        return call.synthesized orelse error.TypeError;
    }

    /// The single node argument of a tree primitive.
    fn nodeArgument(self: *Machine, arguments: []const *value.Thunk) Error!ts.Node {
        if (arguments.len != 1) return error.TypeError;
        return switch (try self.force(arguments[0])) {
            .node => |n| n.inner,
            else => error.TypeError,
        };
    }

    /// Resolve a constructor's field atoms into a value.
    ///
    /// Fields that fit inline are written straight into the value, so a `Cons`
    /// cell costs no allocation of its own.
    fn construct(
        self: *Machine,
        constructor: core.SymbolId,
        tag: u32,
        atoms: []const stg.Atom,
        env: Slots,
    ) Error!value.Constructed {
        if (atoms.len <= value.Constructed.inline_capacity) {
            var built: value.Constructed = .{
                .constructor = constructor,
                .tag = tag,
                .len = @intCast(atoms.len),
                .storage = undefined,
            };
            for (atoms, 0..) |atom, i| {
                built.storage.inline_fields[i] = try self.resolve(env, atom);
            }
            return built;
        }

        const spill = try self.arena.alloc(*value.Thunk, atoms.len);
        for (atoms, spill) |atom, *field| field.* = try self.resolve(env, atom);
        return value.Constructed.init(constructor, tag, spill);
    }

    fn nodeThunk(self: *Machine, n: ts.Node) Error!*value.Thunk {
        note(.node_thunk, @sizeOf(value.Thunk));
        const thunk = try self.arena.create(value.Thunk);
        thunk.* = value.Thunk.value(.{ .node = .{ .inner = n } });
        return thunk;
    }

    fn nil(self: *Machine) Error!value.Value {
        const c = self.program.structural.nil;
        return .{ .constructed = value.Constructed.init(c.symbol, c.tag, &.{}) };
    }

    fn nilThunk(self: *Machine) Error!*value.Thunk {
        return self.program.nil;
    }

    fn cons(self: *Machine, head: *value.Thunk, tail: *value.Thunk) Error!value.Value {
        const c = self.program.structural.cons;
        return .{ .constructed = value.Constructed.init(c.symbol, c.tag, &.{ head, tail }) };
    }

    fn consThunk(self: *Machine, head: *value.Thunk, tail: *value.Thunk) Error!*value.Thunk {
        note(.cons_thunk, @sizeOf(value.Thunk));
        const thunk = try self.arena.create(value.Thunk);
        thunk.* = value.Thunk.value(try self.cons(head, tail));
        return thunk;
    }

    fn singleton(self: *Machine, element: *value.Thunk) Error!value.Value {
        return try self.cons(element, try self.nilThunk());
    }

    /// Yield one cell of a suspended axis, suspending the rest.
    ///
    /// One cell per call, so a consumer that stops early walks no further.
    /// The cursor sits on the node being yielded and is advanced past it
    /// before the tail is suspended.
    fn step(self: *Machine, t: value.Traversal) Error!value.Value {
        // Only a walk that is empty from the start arrives here dead. One that
        // runs out later ends with a plain `Nil` tail below.
        if (!t.live) {
            self.releaseCursor(t.cursor);
            return self.nil();
        }

        const current = t.cursor.node();

        var rest = t;
        rest.live = switch (t.axis) {
            .children => advanceNamedSibling(t.cursor),
            .descendants => advanceDescendant(t.cursor),
            .field => advanceFieldSibling(t.cursor, t.field_id),
            .children_of_kind => advanceSiblingOfKind(t.cursor, t.kind_id),
            .descendants_of_kind => advanceDescendantOfKind(t.cursor, t.kind_id),
        };

        note(.step_tail, @sizeOf(value.Thunk));
        const tail = try self.arena.create(value.Thunk);
        if (rest.live) {
            tail.* = .{ .state = .{ .traversing = rest } };
        } else {
            // The walk is over, so the tail is already known and the cursor
            // is free for the next one.
            tail.* = value.Thunk.value(try self.nil());
            self.releaseCursor(t.cursor);
        }
        return try self.cons(try self.nodeThunk(current), tail);
    }

    fn numbers(left: value.Value, right: value.Value) Error!struct { i64, i64 } {
        const a = switch (left) {
            .number => |n| n,
            else => return error.TypeError,
        };
        const b = switch (right) {
            .number => |n| n,
            else => return error.TypeError,
        };
        return .{ a, b };
    }

    fn ordering(left: value.Value, right: value.Value) Error!std.math.Order {
        // `Ord` holds for `Int` and `String` only, so these two cases
        // are the whole of ordering.
        return switch (left) {
            .number => |a| switch (right) {
                .number => |b| std.math.order(a, b),
                else => error.TypeError,
            },
            .string => |a| switch (right) {
                .string => |b| std.mem.order(u8, a, b),
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    fn operator(
        self: *Machine,
        call: *const stg.Expr.Primitive,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != 2) return error.TypeError;
        const scalar = switch (try synthesized(call)) {
            .operator => |o| o,
            else => return error.TypeError,
        };

        // Both operands are scalars, so both are forced. There is no stream
        // here to be lazy about.
        const left = try self.force(arguments[0]);
        const right = try self.force(arguments[1]);

        switch (scalar) {
            .add => {
                const a, const b = try numbers(left, right);
                return .{ .number = a + b };
            },
            .subtract => {
                const a, const b = try numbers(left, right);
                return .{ .number = a - b };
            },
            .multiply => {
                const a, const b = try numbers(left, right);
                return .{ .number = a * b };
            },
            // Division and modulo by zero are undefined until the language
            // has a Maybe. A scalar operator has no way to yield nothing,
            // so the old "empty stream" answer stopped being expressible
            // when these became scalars.
            .divide => {
                const a, const b = try numbers(left, right);
                if (b == 0) return error.DivideByZero;
                return .{ .number = @divTrunc(a, b) };
            },
            .modulo => {
                const a, const b = try numbers(left, right);
                if (b == 0) return error.DivideByZero;
                return .{ .number = @rem(a, b) };
            },

            .eq => return try self.boolValue(try self.equal(left, right)),
            .ne => return try self.boolValue(!try self.equal(left, right)),

            .lt => return try self.boolValue(try ordering(left, right) == .lt),
            .lte => return try self.boolValue(try ordering(left, right) != .gt),
            .gt => return try self.boolValue(try ordering(left, right) == .gt),
            .gte => return try self.boolValue(try ordering(left, right) != .lt),

            .match, .not_match => {
                const haystack = switch (left) {
                    .string => |s| s,
                    else => return error.TypeError,
                };
                const pattern = switch (right) {
                    .regex => |r| r,
                    else => return error.TypeError,
                };
                if (self.match_data == null) self.match_data = try pcre2.MatchData.create();
                const hit = pattern.compiled.isMatch(haystack, &self.match_data.?);
                return try self.boolValue(if (scalar == .match) hit else !hit);
            },
        }
    }

    /// Structural equality. Forces both sides only as far as it must to
    /// decide.
    fn equal(self: *Machine, left_value: value.Value, right_value: value.Value) Error!bool {
        try self.checkStack();

        var left = left_value;
        var right = right_value;
        while (true) {
            switch (left) {
                .node => |a| switch (right) {
                    .node => |b| return a.inner.eql(b.inner),
                    else => return error.TypeError,
                },
                .range => |a| switch (right) {
                    .range => |b| return std.meta.eql(a, b),
                    else => return error.TypeError,
                },
                .number => |a| switch (right) {
                    .number => |b| return a == b,
                    else => return error.TypeError,
                },
                .string => |a| switch (right) {
                    .string => |b| return std.mem.eql(u8, a, b),
                    else => return error.TypeError,
                },
                .constructed => |a| {
                    const b = switch (right) {
                        .constructed => |c| c,
                        else => return error.TypeError,
                    };
                    if (a.tag != b.tag or a.len != b.len) return false;
                    if (a.len == 0) return true;

                    const xs = a.fields();
                    const ys = b.fields();
                    for (xs[0 .. xs.len - 1], ys[0 .. ys.len - 1]) |x, y| {
                        if (!try self.equal(try self.force(x), try self.force(y))) return false;
                    }
                    // The last field is compared by the next iteration rather
                    // than by recursion, so a list's spine costs no stack.
                    left = try self.force(xs[xs.len - 1]);
                    right = try self.force(ys[ys.len - 1]);
                },
                // Labels are sorted, so the same record type gives the same
                // order on both sides and the fields pair up positionally.
                .record => |a| {
                    const b = switch (right) {
                        .record => |r| r,
                        else => return error.TypeError,
                    };
                    if (a.len != b.len) return false;
                    for (a, b) |x, y| {
                        if (!std.mem.eql(u8, x.label, y.label)) return false;
                        if (!try self.equal(try self.force(x.thunk), try self.force(y.thunk))) return false;
                    }
                    return true;
                },
                else => return error.TypeError,
            }
        }
    }

    fn boolValue(self: *Machine, b: bool) Error!value.Value {
        const c = self.program.structural.boolean(b);
        return .{ .constructed = value.Constructed.init(c.symbol, c.tag, &.{}) };
    }

    /// Fill a `let` binding's thunk. The thunk was allocated before any
    /// binding in the group was evaluated, so the group can be recursive.
    fn fillAllocation(
        self: *Machine,
        thunk: *value.Thunk,
        binding: stg.Allocation,
        env: Slots,
    ) Error!void {
        switch (binding) {
            .closure => |code| {
                // Copied, so the closure outlives the scope it was written in.
                // A closure over nothing needs no copy and no allocation.
                const captured: []*value.Thunk = if (code.free.len == 0) &.{} else blk: {
                    note(.alloc_captured, code.free.len * @sizeOf(*value.Thunk));
                    const slots = try self.arena.alloc(*value.Thunk, code.free.len);
                    for (code.free, slots) |capture, *slot| slot.* = try env.get(capture);
                    break :blk slots;
                };
                thunk.* = .{ .state = .{ .unevaluated = .{
                    .code = code,
                    .captured = captured,
                } } };
            },
            .constructed => |constructed| {
                thunk.* = value.Thunk.value(.{ .constructed = try self.construct(
                    constructed.constructor,
                    constructed.tag,
                    constructed.fields,
                    env,
                ) });
            },
        }
    }

    /// Apply a callee to arguments, handling all three arities.
    ///
    /// - saturated: run the body
    /// - partial: keep the arguments on the closure and stay a value
    /// - over-applied: run the body, then apply the result to the rest
    pub fn apply(
        self: *Machine,
        callee: value.Value,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        var function = callee;
        var remaining = arguments;
        while (remaining.len > 0) {
            const closure = switch (function) {
                .closure => |c| c,
                else => return error.TypeError,
            };
            const needed = closure.code.parameters.len - closure.applied.len;
            if (remaining.len < needed) return try self.partial(closure, remaining);

            note(.apply_all, closure.code.parameters.len * @sizeOf(*value.Thunk));
            const all = try self.arena.alloc(*value.Thunk, closure.code.parameters.len);
            @memcpy(all[0..closure.applied.len], closure.applied);
            @memcpy(all[closure.applied.len..], remaining[0..needed]);

            // Over-applied, the result is a function and the rest are its
            // arguments.
            function = try self.run(closure.code, closure.captured, all);
            remaining = remaining[needed..];
        }
        return function;
    }

    /// Write a forced value as JSON. This is the `Serial` boundary: it forces
    /// everything it writes, and a list is written by walking its spine.
    ///
    /// Returns error.TypeError on a value with no encoding. The checker
    /// refuses those, so reaching one is a bug rather than a bad query.
    pub fn serialize(self: *Machine, v: value.Value, jws: *std.json.Stringify) Error!void {
        try self.checkStack();
        switch (v) {
            .number => |n| try jws.write(n),
            .string => |s| try jws.write(s),
            .record => |fields| {
                try jws.beginObject();
                for (fields) |field| {
                    try jws.objectField(field.label);
                    try self.serialize(try self.force(field.thunk), jws);
                }
                try jws.endObject();
            },
            .constructed => |c| {
                const structural = self.program.structural;
                if (c.constructor == structural.true_.symbol or c.constructor == structural.false_.symbol) {
                    try jws.write(c.constructor == structural.true_.symbol);
                } else if (c.constructor == structural.nil.symbol or c.constructor == structural.cons.symbol) {
                    try jws.beginArray();
                    var current = v;
                    while (true) {
                        const cell = switch (current) {
                            .constructed => |k| k,
                            else => return error.TypeError,
                        };
                        if (cell.tag == structural.nil.tag) break;
                        if (cell.len != 2) return error.TypeError;
                        const cell_fields = cell.fields();
                        try self.serialize(try self.force(cell_fields[0]), jws);
                        current = try self.force(cell_fields[1]);
                    }
                    try jws.endArray();
                } else {
                    // A user datatype, which has no encoding until 0.4 gives
                    // it one.
                    return error.TypeError;
                }
            },
            .node => |n| {
                const target = self.target orelse return error.TypeError;
                const inner = n.inner;
                try jws.beginObject();
                try jws.objectField("kind");
                try jws.write(inner.kind());
                try jws.objectField("text");
                try jws.write(target.source[inner.startByte()..inner.endByte()]);
                try writeLocation(rangeOf(inner), jws);
                try jws.endObject();
            },
            .range => |r| {
                try jws.beginObject();
                try writeLocation(r, jws);
                try jws.endObject();
            },
            else => return error.TypeError,
        }
    }
};

/// The location fields a node and a range share, in the order the public
/// encoding fixes. Starts are inclusive and ends exclusive.
fn writeLocation(r: value.Range, jws: *std.json.Stringify) !void {
    try jws.objectField("start_byte");
    try jws.write(r.start_byte);
    try jws.objectField("end_byte");
    try jws.write(r.end_byte);
    try jws.objectField("start_point");
    try writePoint(r.start_point, jws);
    try jws.objectField("end_point");
    try writePoint(r.end_point, jws);
}

fn writePoint(p: value.Point, jws: *std.json.Stringify) !void {
    try jws.beginObject();
    try jws.objectField("row");
    try jws.write(p.row);
    try jws.objectField("column");
    try jws.write(p.column);
    try jws.endObject();
}

/// Move `cursor` to the first named child, reporting whether one exists.
fn descendToNamedChild(cursor: *ts.TreeCursor) bool {
    if (!cursor.gotoFirstChild()) return false;
    if (cursor.node().isNamed()) return true;
    return advanceNamedSibling(cursor);
}

/// Move `cursor` to the next named sibling, reporting whether one exists.
///
/// `gotoNextSibling` advances an index on the cursor's own stack, so this is
/// amortized constant work per step.
fn advanceNamedSibling(cursor: *ts.TreeCursor) bool {
    while (cursor.gotoNextSibling()) {
        if (cursor.node().isNamed()) return true;
    }
    return false;
}

/// Move `cursor` to the first named child under `field_id`.
fn descendToFieldChild(cursor: *ts.TreeCursor, field_id: u16) bool {
    if (!cursor.gotoFirstChild()) return false;
    if (cursor.node().isNamed() and cursor.fieldId() == field_id) return true;
    return advanceFieldSibling(cursor, field_id);
}

/// Move `cursor` to the next named sibling under `field_id`.
fn advanceFieldSibling(cursor: *ts.TreeCursor, field_id: u16) bool {
    while (cursor.gotoNextSibling()) {
        if (cursor.node().isNamed() and cursor.fieldId() == field_id) return true;
    }
    return false;
}

/// Move `cursor` to its pre-order successor, reporting whether one exists.
///
/// Children first, then the next sibling, ascending while a level is
/// exhausted. A cursor cannot walk above the node it was built from, so the
/// walk stops at the subtree boundary on its own.
///
/// Every move is a step along the cursor's own stack, which is what keeps this
/// linear. `gotoDescendant` looks like the natural call and is not: it
/// re-descends from the top, scanning each level's children from the start, so
/// a node with many flat children costs O(n^2) to walk. Error-recovery trees
/// have exactly that shape.
fn advancePreOrder(cursor: *ts.TreeCursor) bool {
    if (cursor.gotoFirstChild()) return true;
    while (true) {
        if (cursor.gotoNextSibling()) return true;
        if (!cursor.gotoParent()) return false;
    }
}

/// Move a `descendants` walk to its next named node.
fn advanceDescendant(cursor: *ts.TreeCursor) bool {
    while (advancePreOrder(cursor)) {
        if (cursor.node().isNamed()) return true;
    }
    return false;
}

/// Move `cursor` to the next named sibling whose kind is `kind_id`.
fn advanceSiblingOfKind(cursor: *ts.TreeCursor, kind_id: u16) bool {
    while (cursor.gotoNextSibling()) {
        const node = cursor.node();
        if (node.isNamed() and node.kindId() == kind_id) return true;
    }
    return false;
}

/// Move `cursor` to the first named child whose kind is `kind_id`.
fn descendToChildOfKind(cursor: *ts.TreeCursor, kind_id: u16) bool {
    if (!cursor.gotoFirstChild()) return false;
    const node = cursor.node();
    if (node.isNamed() and node.kindId() == kind_id) return true;
    return advanceSiblingOfKind(cursor, kind_id);
}

/// Move a `descendants_of_kind` walk to its next named node of `kind_id`.
///
/// A node of another kind is stepped over, not skipped past: its own subtree
/// is still walked, so a match nested under a non-match is found.
fn advanceDescendantOfKind(cursor: *ts.TreeCursor, kind_id: u16) bool {
    while (advancePreOrder(cursor)) {
        const node = cursor.node();
        if (node.isNamed() and node.kindId() == kind_id) return true;
    }
    return false;
}

fn rangeOf(n: ts.Node) value.Range {
    const start = n.startPoint();
    const end = n.endPoint();
    return .{
        .start_byte = n.startByte(),
        .end_byte = n.endByte(),
        .start_point = .{ .row = start.row, .column = start.column },
        .end_point = .{ .row = end.row, .column = end.column },
    };
}

/// An optional leading `-` and one or more ASCII decimal digits, fitting an
/// `i64`. Every other string, including a leading `+` or a separator, has no
/// integer and yields no output.
fn parseInt(text: []const u8) ?i64 {
    var digits = text;
    var negative = false;
    if (digits.len > 0 and digits[0] == '-') {
        negative = true;
        digits = digits[1..];
    }
    if (digits.len == 0) return null;

    var magnitude: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        magnitude = std.math.mul(u64, magnitude, 10) catch return null;
        magnitude = std.math.add(u64, magnitude, c - '0') catch return null;
    }

    const limit: u64 = if (negative)
        -@as(i128, std.math.minInt(i64))
    else
        std.math.maxInt(i64);
    if (magnitude > limit) return null;

    if (negative) return @intCast(-@as(i128, magnitude));
    return @intCast(magnitude);
}

// ============================================================================
//                              Tests
// ============================================================================

const diagnostic = @import("../diagnostic.zig");
const grammar = @import("../lang/grammar.zig");
const root = @import("../root.zig");

/// Checks and runs `query` against an empty TypeScript file, and asserts its
/// outputs serialize to `expected`.
fn expectValues(expected: []const u8, query: []const u8) !void {
    const allocator = std.testing.allocator;

    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try root.Engine.init(.{ .allocator = allocator, .io = std.testing.io });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    const json = try engine.evaluateQuery(query, "", null, g, &sink, allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(expected, json);
}

test "a constructor's fields bind in declaration order" {
    try expectValues("[7]",
        \\type P = Mk Int Int;
        \\main = pure (case Mk 10 3 of { Mk a b -> a - b });
    );
}

test "a case in a scrutinee leaves the alternative's binders in place" {
    try expectValues("[702]",
        \\type P = Mk Int Int;
        \\first p = case p of { Mk a b -> a };
        \\pick p q = case (case p of { Mk a b -> Mk b a }) of { Mk x y -> x + 100 * first q };
        \\main = pure (pick (Mk 1 2) (Mk 7 8));
    );
}

test "a let in a scrutinee leaves the alternative's binders in place" {
    try expectValues("[765]",
        \\type P = Mk Int Int;
        \\first p = case p of { Mk a b -> a };
        \\pick p q = case (let { s = 5 } in Mk s 6) of { Mk x y -> x + 10 * y + 100 * first q };
        \\main = pure (pick (Mk 1 2) (Mk 7 8));
    );
}

test "an alternative's body sees the binders of every enclosing alternative" {
    try expectValues("[1234]",
        \\type P = Mk Int Int;
        \\main = pure (case Mk 1 2 of {
        \\  Mk a b -> case Mk 3 4 of { Mk c d -> 1000 * a + 100 * b + 10 * c + d }
        \\});
    );
}

test "a closure reads its captures and parameters at their own offsets" {
    try expectValues("[-27]",
        \\main = pure ((\a b c -> (\x -> c - a * x - b)) 1 30 3 0);
    );
}

test "a partial application saturates on a later call" {
    try expectValues("[6]",
        \\add3 a b c = a + b + c;
        \\main = let { f = add3 1 } in let { g = f 2 } in pure (g 3);
    );
}

test "an over-application applies the result to the rest" {
    try expectValues("[11]",
        \\adder a = \b -> a + b;
        \\main = pure (adder 1 10);
    );
}

test "a letrec's closures reach each other" {
    try expectValues("[true,false]",
        \\main =
        \\  let {
        \\    is_even n = if n = 0 then true else is_odd (n - 1);
        \\    is_odd n = if n = 0 then false else is_even (n - 1)
        \\  } in
        \\    const [is_even 4, is_even 7];
    );
}

test "a letrec binding captures an enclosing parameter" {
    try expectValues("[10]",
        \\count_to limit =
        \\  let { go n = if n = limit then n else go (n + 1) } in go 0;
        \\main = pure (count_to 10);
    );
}

test "a regex test reuses one match scratch across calls" {
    try expectValues("[true,false,true]",
        \\main = const ["abc" ~ r"b", "xyz" ~ r"b", "b" ~ r"b"];
    );
}

test "a list literal builds its elements in order" {
    try expectValues("[[1,2,3],[]]",
        \\main = const [[1, 1 + 1, 3], []];
    );
}

test "collect gathers every output into one list" {
    try expectValues("[[1,2],[]]",
        \\main = collect (const [1, 2]) <|> collect none;
    );
}
