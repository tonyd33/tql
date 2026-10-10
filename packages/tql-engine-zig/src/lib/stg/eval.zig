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
    run_env,
    enter_captures,
    let_thunk,
    case_binder,
    range_fields,
    node_thunk,
    cons_thunk,
    step_tail,
    alloc_captured,
    apply_partial,
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

                .let_no_escape => |let| {
                    current = let.body;
                    continue;
                },

                .jump => |jump| {
                    // An argument may read a slot above the join point's
                    // depth, so resolve before shrinking.
                    const target = jump.target;
                    const mark = self.args.items.len;
                    defer self.args.shrinkRetainingCapacity(mark);
                    const arguments = try self.pushArgs(jump.arguments, scope.slots());
                    scope.shrink(target.depth);
                    try scope.appendSlice(self.gpa, arguments, target.parameters);
                    current = target.body;
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
                    const alternative = case_expr.alternativeFor(scrutinee) orelse {
                        current = case_expr.default orelse return error.TypeError;
                        continue;
                    };
                    const constructed = scrutinee.constructed;
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
    /// more. `pure` forces nothing, `null` forces at most the first cell,
    /// `length` forces a whole spine.
    fn primitive(
        self: *Machine,
        call: *const stg.Expr.Primitive,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        switch (call.operation) {
            .synthesized => |synthesized| switch (synthesized) {
                .operator => |scalar| return try self.operator(scalar, arguments),

                // Fields are scalars and stay unforced. The labels come from the
                // symbol's details, already sorted.
                .record => |labels| {
                    if (labels.len != arguments.len) return error.TypeError;

                    const fields = try self.arena.alloc(value.Field, labels.len);
                    for (labels, arguments, fields) |label, thunk, *field| {
                        field.* = .{ .label = label, .thunk = thunk };
                    }
                    return .{ .record = fields };
                },

                // Forces the record, and of its fields only the one selected.
                .select => |label| {
                    if (arguments.len != 1) return error.TypeError;
                    const fields = switch (try self.force(arguments[0])) {
                        .record => |f| f,
                        else => return error.TypeError,
                    };
                    const index = std.sort.binarySearch(value.Field, fields, label, orderLabel) orelse
                        return error.TypeError;
                    return try self.force(fields[index].thunk);
                },

                // Children under one field, named or anonymous, document
                // order. A field the grammar knows but this node lacks yields
                // no output.
                .field => |f| return try self.walk(try self.nodeArgument(arguments), .sibling, .{ .field = f.id }),
            },
            .builtin => |primop| switch (primop) {
                // Floored: the result takes the divisor's sign.
                .mod => {
                    if (arguments.len != 2) return error.TypeError;
                    const a, const b = try numbers(try self.force(arguments[0]), try self.force(arguments[1]));
                    if (b == 0) return error.DivideByZero;
                    const r = @rem(a, b);
                    return .{ .number = if (r != 0 and (r < 0) != (b < 0)) r + b else r };
                },

                .string_length => {
                    if (arguments.len != 1) return error.TypeError;
                    return switch (try self.force(arguments[0])) {
                        .string => |s| .{ .number = @intCast(s.len) },
                        else => error.TypeError,
                    };
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
                    return .{ .kind = .{ .name = subject.kind(), .id = subject.kindId() } };
                },
                .kind_name => {
                    const subject = try self.nodeArgument(arguments);
                    return .{ .string = subject.kind() };
                },
                .is_named => {
                    const subject = try self.nodeArgument(arguments);
                    return try self.boolValue(subject.isNamed());
                },
                .is_extra => {
                    const subject = try self.nodeArgument(arguments);
                    return try self.boolValue(subject.isExtra());
                },
                .range => {
                    const subject = try self.nodeArgument(arguments);
                    return try self.rangeRecord(rangeOf(subject));
                },

                // `[x]` when the kind matches, otherwise `[]`.
                .of_kind => {
                    const tested = try self.kindTestArguments(arguments);
                    if (tested.subject.kindId() != tested.kind_id) return self.nil();
                    return self.singleton(arguments[1]);
                },
                .is_kind => {
                    const tested = try self.kindTestArguments(arguments);
                    return try self.boolValue(tested.subject.kindId() == tested.kind_id);
                },

                inline else => |p| {
                    const c = comptime p.compared() orelse @compileError("no evaluation for " ++ @tagName(p));
                    return try self.comparison(c.comparison, arguments);
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
                    return self.singleton(try self.valueThunk(.{ .number = parsed }));
                },

                // Constant across the query, and it never reads its argument.
                .filename => {
                    const target = self.target orelse return self.nil();
                    const path = target.path orelse return self.nil();
                    return self.singleton(try self.valueThunk(.{ .string = path }));
                },

                // Children and anonymous tokens, document order.
                .children => return try self.walk(try self.nodeArgument(arguments), .sibling, .any),

                // Named children, document order.
                .named_children => return try self.walk(try self.nodeArgument(arguments), .sibling, .named),

                // Proper descendants and anonymous tokens, pre-order. Proper: the
                // walk starts by stepping off the subject, so a node is not its
                // own descendant.
                .descendants => return try self.walk(try self.nodeArgument(arguments), .preorder, .any),

                // Named proper descendants, pre-order.
                .named_descendants => return try self.walk(try self.nodeArgument(arguments), .preorder, .named),

                // The `children`/`descendants` walks with the kind test folded
                // into the advance, so the list holds only matches.
                .children_of_kind, .descendants_of_kind => {
                    const tested = try self.kindTestArguments(arguments);
                    const move: value.Traversal.Move = if (primop == .descendants_of_kind) .preorder else .sibling;
                    return try self.walk(tested.subject, move, .{ .kind = tested.kind_id });
                },
            },
        }
    }

    /// The single node argument of a tree primitive.
    fn nodeArgument(self: *Machine, arguments: []const *value.Thunk) Error!ts.Node {
        if (arguments.len != 1) return error.TypeError;
        return switch (try self.force(arguments[0])) {
            .node => |n| n.inner,
            else => error.TypeError,
        };
    }

    /// The kind and node arguments of `of_kind`, `is_kind` and the `_of_kind`
    /// axes.
    fn kindTestArguments(
        self: *Machine,
        arguments: []const *value.Thunk,
    ) Error!struct { kind_id: u16, subject: ts.Node } {
        if (arguments.len != 2) return error.TypeError;
        const kind_id = switch (try self.force(arguments[0])) {
            .kind => |k| k.id,
            else => return error.TypeError,
        };
        const subject = switch (try self.force(arguments[1])) {
            .node => |n| n.inner,
            else => return error.TypeError,
        };
        return .{ .kind_id = kind_id, .subject = subject };
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

    /// `range`'s record in one block: its four fields, then each point's two.
    fn rangeRecord(self: *Machine, r: value.Range) Error!value.Value {
        note(.range_fields, 8 * (@sizeOf(value.Thunk) + @sizeOf(value.Field)));
        const thunks = try self.arena.alloc(value.Thunk, 8);
        const fields = try self.arena.alloc(value.Field, 8);
        const end_point = fields[4..6];
        const start_point = fields[6..8];
        // In the labels' sorted order.
        const values = [8]value.Value{
            .{ .number = r.end_byte },
            .{ .record = end_point },
            .{ .number = r.start_byte },
            .{ .record = start_point },
            .{ .number = r.end_point.column },
            .{ .number = r.end_point.row },
            .{ .number = r.start_point.column },
            .{ .number = r.start_point.row },
        };
        for (thunks, values) |*thunk, v| thunk.* = value.Thunk.value(v);
        labelFields(fields[0..4], core.types.range_record, thunks[0..4]);
        labelFields(end_point, core.types.point_record, thunks[4..6]);
        labelFields(start_point, core.types.point_record, thunks[6..8]);
        return .{ .record = fields[0..4] };
    }

    fn labelFields(fields: []value.Field, t: core.types.Type, thunks: []value.Thunk) void {
        for (fields, t.record.fields, thunks) |*field, typed, *thunk| {
            field.* = .{ .label = typed.label, .thunk = thunk };
        }
    }

    fn valueThunk(self: *Machine, v: value.Value) Error!*value.Thunk {
        const thunk = try self.arena.create(value.Thunk);
        thunk.* = value.Thunk.value(v);
        return thunk;
    }

    fn nodeThunk(self: *Machine, n: ts.Node) Error!*value.Thunk {
        note(.node_thunk, @sizeOf(value.Thunk));
        return self.valueThunk(.{ .node = .{ .inner = n } });
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

    /// Walk the subtree of `subject` from its first child, yielding each node
    /// `keep` admits as `move` reaches it.
    fn walk(self: *Machine, subject: ts.Node, move: value.Traversal.Move, keep: value.Traversal.Keep) Error!value.Value {
        const t: value.Traversal = .{ .cursor = try self.newCursor(subject), .move = move, .keep = keep };
        if (!t.cursor.gotoFirstChild() or !(keeps(t) or advance(t))) {
            self.releaseCursor(t.cursor);
            return self.nil();
        }
        return try self.step(t);
    }

    /// Yield one cell of a suspended axis, suspending the rest.
    ///
    /// One cell per call, so a consumer that stops early walks no further.
    /// The cursor sits on the node being yielded and is advanced past it
    /// before the tail is suspended.
    fn step(self: *Machine, t: value.Traversal) Error!value.Value {
        const current = t.cursor.node();

        note(.step_tail, @sizeOf(value.Thunk));
        const tail = try self.arena.create(value.Thunk);
        if (advance(t)) {
            tail.* = .{ .state = .{ .traversing = t } };
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

    /// The order of two `Int`s or two `String`s, the primitive types with
    /// `Ord` instances.
    fn ordering(left: value.Value, right: value.Value) Error!std.math.Order {
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

    fn comparison(
        self: *Machine,
        comptime made: core.Comparison,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != 2) return error.TypeError;
        const left = try self.force(arguments[0]);
        const right = try self.force(arguments[1]);
        switch (made) {
            .eq => return try self.boolValue(try equal(left, right)),
            .ne => return try self.boolValue(!try equal(left, right)),
            .lt, .lte, .gt, .gte => return try self.boolValue(made.answer(try ordering(left, right))),
            .compare => {
                const c = self.program.structural.ordering(try ordering(left, right));
                return .{ .constructed = value.Constructed.init(c.symbol, c.tag, &.{}) };
            },
        }
    }

    fn operator(
        self: *Machine,
        scalar: core.Scalar,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != 2) return error.TypeError;

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
            // Division by zero is undefined until the language has a Maybe.
            // A scalar operator has no way to yield nothing, so the old
            // "empty stream" answer stopped being expressible when division
            // became a scalar.
            .divide => {
                const a, const b = try numbers(left, right);
                if (b == 0) return error.DivideByZero;
                return .{ .number = @divTrunc(a, b) };
            },

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

    /// Equality of two values of a primitive type with an `Eq` instance.
    fn equal(left: value.Value, right: value.Value) Error!bool {
        return switch (left) {
            .node => |a| switch (right) {
                .node => |b| a.inner.eql(b.inner),
                else => error.TypeError,
            },
            .number => |a| switch (right) {
                .number => |b| a == b,
                else => error.TypeError,
            },
            .string => |a| switch (right) {
                .string => |b| std.mem.eql(u8, a, b),
                else => error.TypeError,
            },
            .kind => |a| switch (right) {
                .kind => |b| a.id == b.id,
                else => error.TypeError,
            },
            else => error.TypeError,
        };
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

            var env = try self.takeEnv();
            defer self.giveEnv(env);
            const body = try self.enter(closure, remaining[0..needed], &env);
            // Over-applied, the result is a function and the rest are its
            // arguments.
            function = try self.expression(body, &env);
            remaining = remaining[needed..];
        }
        return function;
    }

    /// Returns the head and tail of a forced list cell, both unforced, or
    /// null at `Nil`.
    pub fn uncons(self: *const Machine, list: value.Value) Error!?Cell {
        const c = switch (list) {
            .constructed => |k| k,
            else => return error.TypeError,
        };
        if (c.tag == self.program.structural.nil.tag) return null;
        if (c.len != 2) return error.TypeError;
        const fields = c.fields();
        return .{ .head = fields[0], .tail = fields[1] };
    }

    pub const Cell = struct { head: *value.Thunk, tail: *value.Thunk };

    /// Write a forced list as a JSON array, forcing its spine and every
    /// element.
    ///
    /// Returns the number of elements written.
    pub fn serializeList(self: *Machine, list: value.Value, jws: *std.json.Stringify) Error!usize {
        try jws.beginArray();
        var count: usize = 0;
        var current = list;
        while (try self.uncons(current)) |cell| : (count += 1) {
            try self.serialize(try self.force(cell.head), jws);
            current = try self.force(cell.tail);
        }
        try jws.endArray();
        return count;
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
            .kind => |k| try jws.write(k.name),
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
                    _ = try self.serializeList(v, jws);
                } else {
                    try jws.beginObject();
                    try jws.objectField("tag");
                    try jws.write(self.program.spellings.get(c.constructor) orelse return error.TypeError);
                    try jws.objectField("fields");
                    try jws.beginArray();
                    for (c.fields()) |field| try self.serialize(try self.force(field), jws);
                    try jws.endArray();
                    try jws.endObject();
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
    try jws.write(r.start_point);
    try jws.objectField("end_point");
    try jws.write(r.end_point);
}

/// Move `t.cursor` to the next node `t` keeps, reporting whether one exists.
///
/// A node `t` does not keep is stepped over, not skipped past: in a pre-order
/// walk its own subtree is still walked, so a match nested under a non-match
/// is found. `gotoNextSibling` advances an index on the cursor's own stack, so
/// a sibling move is amortized constant work.
fn advance(t: value.Traversal) bool {
    while (switch (t.move) {
        .sibling => t.cursor.gotoNextSibling(),
        .preorder => advancePreOrder(t.cursor),
    }) {
        if (keeps(t)) return true;
    }
    return false;
}

fn keeps(t: value.Traversal) bool {
    return switch (t.keep) {
        .any => true,
        .named => t.cursor.node().isNamed(),
        .field => |id| t.cursor.fieldId() == id,
        .kind => |id| t.cursor.node().kindId() == id,
    };
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

fn orderLabel(label: []const u8, field: value.Field) std.math.Order {
    return core.types.Type.Field.order(label, field.label);
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
