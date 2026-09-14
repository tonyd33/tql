//! Graph reduction over the STG-shaped term language: force a thunk by running
//! its body, memoize the result, dispatch a `case` on the scrutinee's tag.
//!
//! Calls are eval/apply. The caller reads the callee's arity and decides
//! whether the call is saturated, over-applied, or partial.
//!
//! Everything allocates in one arena owned by the Machine and freed with it.
//! Nothing is collected during a run.

const std = @import("std");
const datatypes = @import("../lang/datatypes.zig");
const desugar = @import("../desugar.zig");
const primitives = @import("../lang/primitives.zig");
const stg = @import("stg.zig");
const symbols = @import("../lang/symbols.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    /// A thunk was re-entered while it was still being evaluated.
    Cycle,
    /// A primitive with no implementation yet. The tree primitives need the
    /// parsed source.
    Unimplemented,
    /// Reached only by a program the type checker should have rejected.
    TypeError,
};

pub const Machine = struct {
    arena: Allocator,
    program: *const stg.Program,
    /// Constructors of `List` and `Bool`, which primitives build directly.
    datatypes: *const datatypes.Registry,
    /// What each synthesized primitive was generated from. `op[+]` and `op[-]`
    /// share a `Lowering`, so the spelling comes from here.
    synthesis: *const desugar.SynthesisTable,
    /// Reaches the prelude definitions a primitive delegates to.
    interner: *const symbols.Interner,
    /// One thunk per global, allocated before the run and forced at most once.
    globals: std.AutoHashMapUnmanaged(symbols.SymbolId, *value.Thunk),

    pub fn init(
        arena: Allocator,
        gpa: Allocator,
        program: *const stg.Program,
        source: *const desugar.Program,
    ) Allocator.Error!Machine {
        var globals: std.AutoHashMapUnmanaged(symbols.SymbolId, *value.Thunk) = .empty;

        // Every global is allocated before any is filled, so one may reference
        // another in any order.
        for (program.definitions) |definition| {
            const thunk = try arena.create(value.Thunk);
            thunk.* = .{ .state = .{ .unevaluated = .{
                .code = definition.value,
                .captured = &.{},
            } } };
            try globals.put(gpa, definition.symbol, thunk);
        }

        return .{
            .arena = arena,
            .program = program,
            .datatypes = &source.datatypes,
            .synthesis = &source.synthesis,
            .interner = &source.interner,
            .globals = globals,
        };
    }

    pub fn deinit(self: *Machine, gpa: Allocator) void {
        self.globals.deinit(gpa);
    }

    /// Read an atom without forcing it.
    fn resolve(self: *Machine, env: []const value.Binding, atom: stg.Atom) Error!*value.Thunk {
        return switch (atom) {
            .local => |name| blk: {
                // Binders are globally unique, so a name appears at most once
                // and the direction is only a search order.
                var i = env.len;
                while (i > 0) {
                    i -= 1;
                    if (env[i].name == name) break :blk env[i].thunk;
                }
                return error.TypeError;
            },
            .global => |id| self.globals.get(id) orelse return error.TypeError,
            .literal => |literal| blk: {
                const thunk = try self.arena.create(value.Thunk);
                thunk.* = value.Thunk.value(switch (literal) {
                    .number => |n| .{ .number = n },
                    .string => |s| .{ .string = s },
                    .regex => |r| .{ .regex = r },
                });
                break :blk thunk;
            },
        };
    }

    /// Force a thunk to a value and memoize it. A closure of one or more
    /// parameters is already a value; only a thunk of none runs its body.
    ///
    /// Returns error.Cycle if the thunk is already being evaluated.
    pub fn force(self: *Machine, thunk: *value.Thunk) Error!value.Value {
        switch (thunk.state) {
            .evaluated => |v| return v,
            .evaluating => return error.Cycle,
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
        captured: []const value.Binding,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != code.parameters.len) return error.TypeError;

        var env: std.ArrayList(value.Binding) = .empty;
        defer env.deinit(self.envAllocator());

        try env.appendSlice(self.envAllocator(), captured);
        for (code.parameters, arguments) |name, thunk| {
            try env.append(self.envAllocator(), .{ .name = name, .thunk = thunk });
        }

        return try self.expression(code.body, &env);
    }

    // IMPROVE: environments are LIFO but the arena frees nothing until the run
    // ends, so a deep recursion retains a backing array per activation whether
    // or not it's live. A stack allocator would fit these exactly.
    fn envAllocator(self: *Machine) Allocator {
        return self.arena;
    }

    fn expression(
        self: *Machine,
        expr: stg.Expr,
        env: *std.ArrayList(value.Binding),
    ) Error!value.Value {
        switch (expr) {
            .atom => |atom| return try self.force(try self.resolve(env.items, atom)),

            .constructed => |constructed| {
                const fields = try self.arena.alloc(*value.Thunk, constructed.fields.len);
                for (constructed.fields, fields) |atom, *field| {
                    field.* = try self.resolve(env.items, atom);
                }
                return .{ .constructed = .{
                    .constructor = constructed.constructor,
                    .tag = constructed.tag,
                    .fields = fields,
                } };
            },

            .let => |let| {
                const base = env.items.len;
                for (let.bindings) |binding| {
                    const thunk = try self.arena.create(value.Thunk);
                    try env.append(self.envAllocator(), .{ .name = binding.binder, .thunk = thunk });
                }

                // A recursive group is filled against the environment holding
                // all of its own binders, so a binding may reference one that
                // comes later. A non-recursive one is filled against the
                // environment as it stood before the group, so a binding sees
                // only what was already in scope.
                const scope = if (let.recursive) env.items else env.items[0..base];
                for (let.bindings, base..) |binding, i| {
                    try self.fillAllocation(env.items[i].thunk, binding.value, scope);
                }
                return try self.expression(let.body, env);
            },

            .case => |case_expr| {
                const scrutinee = try self.expression(case_expr.scrutinee, env);
                const constructed = switch (scrutinee) {
                    .constructed => |c| c,
                    else => return error.TypeError,
                };

                // Alternatives are in tag order and cover every constructor,
                // so the tag is the index.
                if (constructed.tag >= case_expr.alternatives.len) return error.TypeError;
                const alternative = case_expr.alternatives[constructed.tag];
                if (alternative.binders.len != constructed.fields.len) return error.TypeError;

                const mark = env.items.len;
                for (alternative.binders, constructed.fields) |name, field| {
                    try env.append(self.envAllocator(), .{ .name = name, .thunk = field });
                }
                const result = try self.expression(alternative.body, env);
                env.shrinkRetainingCapacity(mark);
                return result;
            },

            .apply => |call| {
                const callee = try self.force(try self.resolve(env.items, call.callee));
                const arguments = try self.arena.alloc(*value.Thunk, call.arguments.len);
                for (call.arguments, arguments) |atom, *argument| {
                    argument.* = try self.resolve(env.items, atom);
                }
                return try self.apply(callee, arguments);
            },

            .primitive => |call| {
                const arguments = try self.arena.alloc(*value.Thunk, call.arguments.len);
                for (call.arguments, arguments) |atom, *argument| {
                    argument.* = try self.resolve(env.items, atom);
                }
                return try self.primitive(call, arguments);
            },
        }
    }

    /// Run a primitive, forcing exactly what its denotation forces and no
    /// more. `pure` forces nothing, `probe` forces at most the first result,
    /// `length` forces a whole spine.
    fn primitive(
        self: *Machine,
        call: *const stg.Expr.Primitive,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        switch (call.lowering) {
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
                            if (c.tag == self.datatypes.nilConstructor().tag) break;
                            if (c.fields.len != 2) return error.TypeError;
                            count += 1;
                            current = try self.force(c.fields[1]);
                        }
                        break :blk .{ .number = count };
                    },
                    else => error.TypeError,
                };
            },

            .operator => return try self.operator(call, arguments),

            // Fields are scalars and stay unforced. The labels come from the
            // synthesis table, already sorted.
            .record => {
                const synthesis = self.synthesis.get(call.symbol) orelse return error.TypeError;
                const labels = switch (synthesis) {
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

            // TODO: the tree primitives, once the parsed source is threaded in
            else => return error.Unimplemented,
        }
    }

    fn operator(
        self: *Machine,
        call: *const stg.Expr.Primitive,
        arguments: []const *value.Thunk,
    ) Error!value.Value {
        if (arguments.len != 2) return error.TypeError;
        const synthesis = self.synthesis.get(call.symbol) orelse return error.TypeError;
        const scalar = switch (synthesis) {
            .operator => |o| o,
            else => return error.TypeError,
        };

        // Both operands are scalars, so both are forced. There is no stream
        // here to be lazy about.
        const left = try self.force(arguments[0]);
        const right = try self.force(arguments[1]);

        switch (scalar) {
            .add, .subtract, .multiply, .divide, .modulo => {
                const a = switch (left) {
                    .number => |n| n,
                    else => return error.TypeError,
                };
                const b = switch (right) {
                    .number => |n| n,
                    else => return error.TypeError,
                };
                // Division and modulo by zero are undefined until the language
                // has a Maybe. A scalar operator has no way to yield nothing,
                // so the old "empty stream" answer stopped being expressible
                // when these became scalars.
                return .{ .number = switch (scalar) {
                    .add => a + b,
                    .subtract => a - b,
                    .multiply => a * b,
                    .divide => if (b == 0) return error.Unimplemented else @divTrunc(a, b),
                    .modulo => if (b == 0) return error.Unimplemented else @rem(a, b),
                    else => unreachable,
                } };
            },

            .eq => return try self.boolValue(try self.equal(left, right)),
            .ne => return try self.boolValue(!try self.equal(left, right)),

            .lt, .lte, .gt, .gte => {
                // `Ord` holds for `Int` and `String` only, so these two cases
                // are the whole of ordering.
                const order: std.math.Order = switch (left) {
                    .number => |a| switch (right) {
                        .number => |b| std.math.order(a, b),
                        else => return error.TypeError,
                    },
                    .string => |a| switch (right) {
                        .string => |b| std.mem.order(u8, a, b),
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                };
                return try self.boolValue(switch (scalar) {
                    .lt => order == .lt,
                    .lte => order != .gt,
                    .gt => order == .gt,
                    .gte => order != .lt,
                    else => unreachable,
                });
            },

            // TODO: `~` and `!~`, which need the regex engine
            .match, .not_match => return error.Unimplemented,
        }
    }

    /// Structural equality. Forces both sides only as far as it must to
    /// decide.
    ///
    // TODO: `Eq` also holds for node and range, which need the parsed tree
    fn equal(self: *Machine, left: value.Value, right: value.Value) Error!bool {
        return switch (left) {
            .number => |a| switch (right) {
                .number => |b| a == b,
                else => error.TypeError,
            },
            .string => |a| switch (right) {
                .string => |b| std.mem.eql(u8, a, b),
                else => error.TypeError,
            },
            .constructed => |a| switch (right) {
                .constructed => |b| blk: {
                    if (a.tag != b.tag) break :blk false;
                    if (a.fields.len != b.fields.len) break :blk false;
                    for (a.fields, b.fields) |x, y| {
                        if (!try self.equal(try self.force(x), try self.force(y))) break :blk false;
                    }
                    break :blk true;
                },
                else => error.TypeError,
            },
            // Labels are sorted, so the same record type gives the same order
            // on both sides and the fields pair up positionally.
            .record => |a| switch (right) {
                .record => |b| blk: {
                    if (a.len != b.len) break :blk false;
                    for (a, b) |x, y| {
                        if (!std.mem.eql(u8, x.label, y.label)) break :blk false;
                        if (!try self.equal(try self.force(x.thunk), try self.force(y.thunk))) {
                            break :blk false;
                        }
                    }
                    break :blk true;
                },
                else => error.TypeError,
            },
            .node, .range => error.Unimplemented,
            else => error.TypeError,
        };
    }

    fn boolValue(self: *Machine, b: bool) Error!value.Value {
        const constructor = self.datatypes.boolConstructor(b);
        return .{ .constructed = .{
            .constructor = constructor.symbol,
            .tag = constructor.tag,
            .fields = &.{},
        } };
    }

    /// Fill a `let` binding's thunk. The thunk was allocated before any
    /// binding in the group was evaluated, so the group can be recursive.
    fn fillAllocation(
        self: *Machine,
        thunk: *value.Thunk,
        binding: stg.Allocation,
        env: []const value.Binding,
    ) Error!void {
        switch (binding) {
            .closure => |code| {
                // Copied, so the closure outlives the scope it was written in.
                const captured = try self.arena.alloc(value.Binding, code.free.len);
                for (code.free, captured) |name, *slot| {
                    slot.* = .{
                        .name = name,
                        .thunk = try self.resolve(env, .{ .local = name }),
                    };
                }
                thunk.* = .{ .state = .{ .unevaluated = .{
                    .code = code,
                    .captured = captured,
                } } };
            },
            .constructed => |constructed| {
                const fields = try self.arena.alloc(*value.Thunk, constructed.fields.len);
                for (constructed.fields, fields) |atom, *field| {
                    field.* = try self.resolve(env, atom);
                }
                thunk.* = value.Thunk.value(.{ .constructed = .{
                    .constructor = constructed.constructor,
                    .tag = constructed.tag,
                    .fields = fields,
                } });
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
        if (arguments.len == 0) return callee;

        const closure = switch (callee) {
            .closure => |c| c,
            else => return error.TypeError,
        };

        const supplied = closure.applied.len + arguments.len;
        const arity = closure.code.parameters.len;

        if (supplied < arity) {
            // Partial: remember what was supplied and stay a value.
            const applied = try self.arena.alloc(*value.Thunk, supplied);
            @memcpy(applied[0..closure.applied.len], closure.applied);
            @memcpy(applied[closure.applied.len..], arguments);
            return .{ .closure = .{
                .code = closure.code,
                .captured = closure.captured,
                .applied = applied,
            } };
        }

        const all = try self.arena.alloc(*value.Thunk, supplied);
        @memcpy(all[0..closure.applied.len], closure.applied);
        @memcpy(all[closure.applied.len..], arguments);

        const result = try self.run(closure.code, closure.captured, all[0..arity]);

        // Over-applied: the result is a function, and the rest are its
        // arguments. `compose f g x` reaches this on every pipe.
        if (supplied > arity) return try self.apply(result, all[arity..]);
        return result;
    }

    /// Write a forced value as JSON. This is the `Serial` boundary: it forces
    /// everything it writes, and a list is written by walking its spine.
    ///
    /// Returns error.TypeError on a value with no encoding. The checker
    /// refuses those, so reaching one is a bug rather than a bad query.
    pub fn serialize(self: *Machine, v: value.Value, jws: *std.json.Stringify) Error!void {
        switch (v) {
            .number => |n| jws.write(n) catch return error.TypeError,
            .string => |s| jws.write(s) catch return error.TypeError,
            .record => |fields| {
                jws.beginObject() catch return error.TypeError;
                for (fields) |field| {
                    jws.objectField(field.label) catch return error.TypeError;
                    try self.serialize(try self.force(field.thunk), jws);
                }
                jws.endObject() catch return error.TypeError;
            },
            .constructed => |c| {
                const owner = self.datatypes.ownerOf(c.constructor) orelse return error.TypeError;
                if (owner == self.datatypes.boolId()) {
                    const t = self.datatypes.boolConstructor(true);
                    jws.write(c.tag == t.tag) catch return error.TypeError;
                } else if (owner == self.datatypes.listId()) {
                    jws.beginArray() catch return error.TypeError;
                    var current = v;
                    while (true) {
                        const cell = switch (current) {
                            .constructed => |k| k,
                            else => return error.TypeError,
                        };
                        if (cell.tag == self.datatypes.nilConstructor().tag) break;
                        if (cell.fields.len != 2) return error.TypeError;
                        try self.serialize(try self.force(cell.fields[0]), jws);
                        current = try self.force(cell.fields[1]);
                    }
                    jws.endArray() catch return error.TypeError;
                } else {
                    // A user datatype, which has no encoding until 0.4 gives
                    // it one.
                    return error.TypeError;
                }
            },
            // TODO: node and range, once the tree primitives exist
            else => return error.TypeError,
        }
    }
};
