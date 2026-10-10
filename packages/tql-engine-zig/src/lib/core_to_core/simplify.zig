//! One simplifying traversal of a definition: top down, carrying a
//! substitution and the continuation of the term being simplified.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const Laws = @import("laws.zig").Laws;
const cost = @import("cost.zig");
const Options = @import("options.zig").Options;
const Analyser = @import("occurrence.zig").Analyser;

const Allocator = std.mem.Allocator;
const Occurrence = @import("occurrence.zig").Occurrence;
const Table = @import("occurrence.zig").Table;

pub const Error = Allocator.Error;

/// Which functions a call may inline.
pub const Phase = enum {
    /// Every function but those a law matches on.
    laws,
    final,
};

/// An operand waiting for its function, with the span of its application.
const Argument = struct {
    operand: Substitution,
    span: diagnostic.Span,
};

/// What the term being simplified is consumed by. A continuation is a slice
/// of frames, innermost first, and the empty slice returns the term as it
/// stands.
const Frame = union(enum) {
    /// Apply it to an operand.
    apply: Argument,
    /// Scrutinize it.
    select: Select,
};

const Select = struct {
    alternatives: []const core.Case.Alternative,
    default: ?core.Term,
    span: diagnostic.Span,
    /// The alternatives are simplified under what followed this frame, and
    /// each is trivial or a jump. Nothing follows the frame, and each use
    /// copies the alternatives with fresh binders.
    dupable: bool = false,
};

/// A term, and whether it is simplified yet.
const Substitution = union(enum) {
    /// Not yet simplified. Taken at its one occurrence.
    suspended: core.Term,
    /// Already simplified.
    done: core.Term,

    fn value(self: Substitution) core.Term {
        return switch (self) {
            .suspended, .done => |t| t,
        };
    }
};

/// A saturated constructor application.
const Constructed = struct {
    constructor: core.SymbolId,
    fields: []const core.Term,
};

/// Rewrites, each reading the occurrence table:
///
/// - beta: `(\x -> b) a` binds `x` to `a`;
/// - let floating: `E[let x = e in b]` is `let x = e in E[b]`, for an
///   application or `case` frame `E`;
/// - a dead binding is dropped;
/// - a binding used once, in one branch, outside any lambda, or whose value
///   is a lambda, moves to its occurrence;
/// - a binding whose value is trivial is substituted everywhere;
/// - a `case` of a known constructor takes its alternative;
/// - case of case: `E[case s of { p -> e }]` is `case s of { p -> E[e] }`;
/// - a join point takes the continuation into its value,
///   `E[let j = \x -> u in b]` is `let j = \x -> E[u] in E[b]`, and a jump
///   drops it, `E[j a]` is `j a`;
/// - a saturated call to a function with an unfolding small enough, or
///   marked to always inline, is replaced by a copy of the unfolding;
/// - the laws.
///
/// Before a continuation is copied into several places it is made dupable:
/// an operand that is not trivial is bound by a `let`, and each alternative
/// of a `case` frame is simplified under the rest of the continuation and,
/// unless trivial, bound to a new join point.
///
/// Binders are unique, so the substitution needs no scopes. A copied
/// unfolding gets a fresh binder for each of its own, and is analysed.
pub const Simplifier = struct {
    builder: core.Builder,
    /// Continuations and the tables below.
    scratch: Allocator,
    env: *core.env.Env,
    /// Holds the occurrence table, and analyses each copied unfolding into it.
    analyser: *Analyser,
    laws: Laws,
    options: Options,
    phase: Phase,
    substitution: core.SymbolTable(Substitution),
    /// Locals bound to a constructor of trivial arguments.
    known: core.SymbolTable(Constructed),
    /// Each binding that may be inlined, by its simplified value.
    unfoldings: core.SymbolTable(core.Term),
    /// Whether a rewrite fired.
    changed: bool = false,

    /// Preconditions: `analyser` has analysed every term this simplifies, and
    /// reads `env`.
    pub fn init(analyser: *Analyser, env: *core.env.Env, options: Options, phase: Phase) Simplifier {
        const builder = analyser.builder;
        const scratch = analyser.scratch;
        return .{
            .builder = builder,
            .scratch = scratch,
            .env = env,
            .analyser = analyser,
            .laws = .{
                .builder = builder,
                .interner = &env.interner,
                .classes = &env.classes,
                .primitives = &env.primitives,
                .kleisli = env.known.get(.kleisli),
                .concat_map = env.known.get(.concat_map),
                .nil = env.datatypes.nilConstructor().symbol,
                .cons = env.datatypes.consConstructor().symbol,
                .false_ = env.datatypes.boolConstructor(false).symbol,
                .true_ = env.datatypes.boolConstructor(true).symbol,
                .ordering = .{
                    env.datatypes.orderingConstructor(.lt).symbol,
                    env.datatypes.orderingConstructor(.eq).symbol,
                    env.datatypes.orderingConstructor(.gt).symbol,
                },
            },
            .options = options,
            .phase = phase,
            .substitution = .init(scratch),
            .known = .init(scratch),
            .unfoldings = .init(scratch),
        };
    }

    /// Record `value`, simplified, as `name`'s unfolding, when `name` is not a
    /// loop breaker and `value` is a lambda or trivial.
    pub fn unfold(self: *Simplifier, name: core.SymbolId, value: core.Term) Error!void {
        if (self.recorded(name) == .loop_breaker) return;
        if (cost.trivial(value)) {
            if (!self.options.post_inline) return;
        } else if (value.kind != .lambda) return;
        try self.unfoldings.put(name, value);
    }

    fn recorded(self: *const Simplifier, binder: core.SymbolId) Occurrence {
        return self.analyser.table.get(binder).?;
    }

    pub fn simplify(self: *Simplifier, t: core.Term) Error!core.Term {
        return try self.term(t, &.{});
    }

    /// Simplify `t` under `continuation`.
    fn term(self: *Simplifier, t: core.Term, continuation: []const Frame) Error!core.Term {
        switch (t.kind) {
            .literal => return try self.rebuild(t, continuation),
            .symbol => |id| {
                // A jump drops everything past its arguments: its join
                // point's value took that in. A value substituted before
                // being simplified takes it at the one jump instead.
                const kept = if (self.env.interner.details(id).joinArity()) |arity| continuation[0..arity] else continuation;
                if (self.substitution.get(id)) |entry| return switch (entry) {
                    .suspended => |value| try self.term(value, continuation),
                    // Simplifying `value` may have outdated the records of
                    // the binders in it.
                    .done => |value| if (kept.len == 0)
                        value
                    else
                        try self.term(try self.analyser.analyse(value), kept),
                };
                if (try self.inlined(id, kept)) |unfolded| {
                    self.changed = true;
                    return try self.term(unfolded, kept);
                }
                return try self.rebuild(t, kept);
            },
            .apply => return try self.term(t.head(), try self.unwind(t, false, continuation)),
            .lambda => |lambda| {
                const applied = appliedTo(continuation);
                if (applied == 0 or !self.options.beta) {
                    const rebuilt = try self.builder.lambda(lambda.parameter, try self.term(lambda.body, &.{}), t.span);
                    return try self.rebuild(rebuilt, continuation);
                }
                self.changed = true;
                // Applied to fewer arguments than the chain takes, the
                // parameter's uses stay under the rest of the chain.
                const occurrence = self.recorded(lambda.parameter);
                const seen = if (applied < t.arity()) occurrence.insideLambda() else occurrence;
                return try self.bind(lambda.parameter, seen, continuation[0].apply.operand, lambda.body, continuation[1..], t.span);
            },
            .let => |let| {
                if (continuation.len > 0 and !self.options.let_from_head) {
                    return try self.rebuild(try self.term(t, &.{}), continuation);
                }
                if (continuation.len > 0) self.changed = true;
                return try self.bind(let.name, self.recorded(let.name), .{ .suspended = let.value }, let.body, continuation, t.span);
            },
            .letrec => |letrec| {
                if (continuation.len > 0 and !self.options.let_from_head) {
                    return try self.rebuild(try self.term(t, &.{}), continuation);
                }
                if (continuation.len > 0) self.changed = true;

                var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
                const inner = try self.bindingContinuation(letrec.bindings[0].name, continuation, &bindings);
                const group = try self.builder.slice(core.Letrec.Binding, letrec.bindings.len);
                for (letrec.bindings, group) |old, *new| {
                    new.* = .{ .name = old.name, .value = try self.bindingValue(old.name, old.value, inner) };
                    try self.unfold(new.name, new.value);
                }
                return try self.builder.lets(bindings.items, try self.builder.letrec(group, try self.term(letrec.body, inner), t.span), t.span);
            },
            .case => |case_term| {
                const frames = try self.scratch.alloc(Frame, continuation.len + 1);
                frames[0] = .{ .select = .{
                    .alternatives = case_term.alternatives,
                    .default = case_term.default,
                    .span = t.span,
                } };
                @memcpy(frames[1..], continuation);
                return try self.term(case_term.scrutinee, frames);
            },
        }
    }

    /// Hand `head`, simplified, to `continuation`: apply it to each operand,
    /// trying the laws at every application, until a `case` frame takes it.
    /// What a law rewrites to resumes under the rest.
    fn rebuild(self: *Simplifier, head: core.Term, continuation: []const Frame) Error!core.Term {
        var result = head;
        for (continuation, 0..) |frame, i| switch (frame) {
            .apply => |argument| {
                const operand = try self.simplifiedOperand(argument);
                const law = if (self.options.laws) try self.laws.apply(result, operand, argument.span) else null;
                if (law) |rewritten| {
                    self.changed = true;
                    return try self.reenter(rewritten, continuation[i + 1 ..]);
                }
                result = try self.builder.apply(result, operand, argument.span);
            },
            .select => |case_frame| return try self.rebuildCase(result, case_frame, continuation[i + 1 ..]),
        };
        return result;
    }

    /// Simplify `t`, already simplified, again under `continuation` from its
    /// head. Its operands are taken as they are.
    fn reenter(self: *Simplifier, t: core.Term, continuation: []const Frame) Error!core.Term {
        const frames = try self.unwind(t, true, continuation);
        const head = t.head();
        if (head.kind == .symbol) return try self.term(head, frames);
        return try self.rebuild(head, frames);
    }

    /// The operands of `t`'s application spine as frames, before
    /// `continuation`. `simplified` says whether the operands are.
    fn unwind(self: *Simplifier, t: core.Term, simplified: bool, continuation: []const Frame) Error![]const Frame {
        const spine = t.spineLength();
        const frames = try self.scratch.alloc(Frame, spine + continuation.len);
        @memcpy(frames[spine..], continuation);
        var walk = t;
        var i = spine;
        while (walk.kind == .apply) : (walk = walk.kind.apply.function) {
            i -= 1;
            const argument = walk.kind.apply.argument;
            frames[i] = .{ .apply = .{
                .operand = if (simplified) .{ .done = argument } else .{ .suspended = argument },
                .span = walk.span,
            } };
        }
        return frames;
    }

    /// `argument`'s operand, simplified.
    fn simplifiedOperand(self: *Simplifier, argument: Argument) Error!core.Term {
        return switch (argument.operand) {
            .suspended => |t| try self.term(t, &.{}),
            .done => |t| t,
        };
    }

    /// Simplify `body` under `continuation` with `name`, used as `occurrence`
    /// says, bound to `value`.
    fn bind(
        self: *Simplifier,
        name: core.SymbolId,
        occurrence: Occurrence,
        value: Substitution,
        body: core.Term,
        continuation: []const Frame,
        span: diagnostic.Span,
    ) Error!core.Term {
        switch (occurrence) {
            .dead => if (self.options.dead_bindings) {
                self.changed = true;
                return try self.term(body, continuation);
            },
            .once => |once| if (self.options.pre_inline and movable(once, value.value())) {
                self.changed = true;
                try self.substitution.put(name, value);
                return try self.term(body, continuation);
            },
            .many, .loop_breaker => {},
        }

        var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
        const inner = try self.bindingContinuation(name, continuation, &bindings);
        const simplified = switch (value) {
            .suspended => |t| try self.bindingValue(name, t, inner),
            .done => |t| t,
        };
        if (!try self.bindSimplified(name, occurrence, simplified)) return try self.builder.lets(bindings.items, try self.term(body, inner), span);
        try self.unfold(name, simplified);
        return try self.builder.lets(bindings.items, try self.builder.let(name, simplified, try self.term(body, inner), span), span);
    }

    /// The continuation a binding of `name` scopes over: `continuation`, made
    /// dupable when `name` is a join point.
    fn bindingContinuation(
        self: *Simplifier,
        name: core.SymbolId,
        continuation: []const Frame,
        bindings: *std.ArrayList(core.Letrec.Binding),
    ) Error![]const Frame {
        if (continuation.len == 0 or self.env.interner.details(name) != .join) return continuation;
        return try self.dupable(continuation, bindings);
    }

    /// `name`'s value, simplified. A join point's body is simplified under
    /// `continuation`.
    fn bindingValue(self: *Simplifier, name: core.SymbolId, value: core.Term, continuation: []const Frame) Error!core.Term {
        const arity = self.env.interner.details(name).joinArity() orelse return try self.term(value, &.{});
        return try self.joinValue(value, arity, continuation);
    }

    /// A join point's value with the body under its `arity` lambdas simplified
    /// under `continuation`.
    fn joinValue(self: *Simplifier, value: core.Term, arity: u32, continuation: []const Frame) Error!core.Term {
        const parameters = try self.scratch.alloc(core.SymbolId, arity);
        const body = value.peel(parameters);
        return try self.builder.abstract(parameters, try self.term(body, continuation));
    }

    /// Bind `name`, used as `occurrence` says, to `value`, already simplified,
    /// by substitution when it may be. Returns whether `name` must still be
    /// bound by a `let`.
    fn bindSimplified(
        self: *Simplifier,
        name: core.SymbolId,
        occurrence: Occurrence,
        value: core.Term,
    ) Error!bool {
        const trivial = self.options.post_inline and cost.trivial(value);
        const substituted = switch (occurrence) {
            .dead => self.options.dead_bindings or trivial,
            .once => |once| (self.options.pre_inline and movable(once, value)) or trivial,
            .many, .loop_breaker => trivial,
        };
        if (substituted) {
            self.changed = true;
            try self.substitution.put(name, .{ .done = value });
            return false;
        }
        if (try self.constructed(value)) |c| {
            for (c.fields) |field| if (!cost.trivial(field)) return true;
            try self.known.put(name, c);
        }
        return true;
    }

    /// Hand `head`, simplified, to the `case` frame `frame`, followed by
    /// `rest`.
    fn rebuildCase(self: *Simplifier, head: core.Term, frame: Select, rest: []const Frame) Error!core.Term {
        var scrutinee = head;
        const instance = if (frame.dupable) try self.instantiate(frame) else frame;
        var case_alternatives = instance.alternatives;
        const default = instance.default;
        const span = frame.span;

        if (self.options.laws and default == null) {
            if (self.laws.foldComparison(scrutinee, case_alternatives)) |folded| {
                self.changed = true;
                const call = try self.builder.applyMany(self.builder.symbol(folded.comparison, scrutinee.span), &.{ folded.left, folded.right }, span);
                return try self.rebuild(call, rest);
            }
            if (try self.laws.rewriteCase(scrutinee, case_alternatives, span)) |rewritten| {
                self.changed = true;
                scrutinee = rewritten.scrutinee;
                case_alternatives = rewritten.alternatives;
            }
        }
        const known = if (self.options.case_of_known_constructor) try self.knownConstructor(scrutinee) else null;
        if (known) |known_constructor| {
            for (case_alternatives) |alternative| {
                if (alternative.constructor != known_constructor.constructor) continue;
                self.changed = true;
                return try self.take(alternative, known_constructor.fields, rest, span);
            }
        }
        const evaluated = known != null or (self.options.case_of_known_constructor and whnf(scrutinee));
        if (default) |body| {
            if (evaluated) {
                self.changed = true;
                return try self.term(body, rest);
            }
        }

        // Case of case, or of an application: `rest` moves into every
        // alternative.
        var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
        var inner = rest;
        if (rest.len > 0) {
            self.changed = true;
            const copies = case_alternatives.len + @intFromBool(default != null);
            if (copies > 1) inner = try self.dupable(rest, &bindings);
        }

        const alternatives = try self.builder.slice(core.Case.Alternative, case_alternatives.len);
        for (case_alternatives, alternatives) |old, *new| {
            new.* = .{
                .constructor = old.constructor,
                .binders = old.binders,
                .body = try self.term(old.body, inner),
            };
        }
        const simplified_default = if (default) |body| try self.term(body, inner) else null;
        return try self.builder.lets(bindings.items, try self.builder.caseWithDefault(scrutinee, alternatives, simplified_default, span), span);
    }

    /// `continuation` made safe to copy into several places, with the
    /// bindings that achieve it appended to `bindings`, outermost first.
    ///
    /// An operand that is not trivial is bound by a `let`. The first `case`
    /// frame has its alternatives simplified under the frames after it, each
    /// bound to a new join point unless trivial, and ends the result.
    fn dupable(self: *Simplifier, continuation: []const Frame, bindings: *std.ArrayList(core.Letrec.Binding)) Error![]const Frame {
        var frames: std.ArrayList(Frame) = .empty;
        for (continuation, 0..) |frame, i| switch (frame) {
            .apply => |argument| {
                const operand = try self.simplifiedOperand(argument);
                const bound = if (cost.trivial(operand)) operand else blk: {
                    const name = try self.env.interner.fresh("a");
                    try bindings.append(self.scratch, .{ .name = name, .value = operand });
                    break :blk self.builder.symbol(name, operand.span);
                };
                try frames.append(self.scratch, .{ .apply = .{ .operand = .{ .done = bound }, .span = argument.span } });
            },
            .select => |case_frame| {
                if (!case_frame.dupable) {
                    const rest = try self.dupable(continuation[i + 1 ..], bindings);
                    const alternatives = try self.builder.slice(core.Case.Alternative, case_frame.alternatives.len);
                    for (case_frame.alternatives, alternatives) |old, *new| {
                        new.* = .{
                            .constructor = old.constructor,
                            .binders = old.binders,
                            .body = try self.dupableBody(old.binders, old.body, rest, bindings),
                        };
                    }
                    const default = if (case_frame.default) |body| try self.dupableBody(&.{}, body, rest, bindings) else null;
                    try frames.append(self.scratch, .{ .select = .{
                        .alternatives = alternatives,
                        .default = default,
                        .span = case_frame.span,
                        .dupable = true,
                    } });
                } else {
                    try frames.append(self.scratch, frame);
                }
                break;
            },
        };
        return frames.items;
    }

    /// An alternative's `body`, under `binders`, simplified under
    /// `continuation`, and moved into a new join point appended to
    /// `bindings` unless trivial.
    fn dupableBody(
        self: *Simplifier,
        binders: []const core.SymbolId,
        body: core.Term,
        continuation: []const Frame,
        bindings: *std.ArrayList(core.Letrec.Binding),
    ) Error!core.Term {
        const simplified = try self.term(body, continuation);
        if (cost.trivial(simplified)) return simplified;

        const join = try self.env.interner.fresh("j");
        self.env.interner.setDetails(join, .{ .join = .{ .arity = @intCast(binders.len) } });
        try bindings.append(self.scratch, .{ .name = join, .value = try self.builder.abstract(binders, simplified) });

        const arguments = try self.builder.slice(core.Term, binders.len);
        for (binders, arguments) |binder, *argument| argument.* = self.builder.symbol(binder, simplified.span);
        return try self.builder.applyMany(self.builder.symbol(join, simplified.span), arguments, simplified.span);
    }

    /// A dupable frame with fresh binders in its alternatives, for one use.
    fn instantiate(self: *Simplifier, frame: Select) Error!Select {
        var renamed: std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId) = .empty;
        const alternatives = try self.builder.slice(core.Case.Alternative, frame.alternatives.len);
        for (frame.alternatives, alternatives) |old, *new| {
            if (old.binders.len == 0) {
                new.* = old;
                continue;
            }
            new.* = try self.copyAlternative(old, &renamed);
            for (old.binders, new.binders) |binder, renamed_binder| {
                try self.analyser.table.put(renamed_binder, self.recorded(binder));
            }
        }
        return .{ .alternatives = alternatives, .default = frame.default, .span = frame.span };
    }

    /// Take `alternative` with its binders bound to `fields`, under
    /// `continuation`.
    fn take(
        self: *Simplifier,
        alternative: core.Case.Alternative,
        fields: []const core.Term,
        continuation: []const Frame,
        span: diagnostic.Span,
    ) Error!core.Term {
        var kept: std.ArrayList(core.Letrec.Binding) = .empty;
        for (alternative.binders, fields) |binder, field| {
            if (!try self.bindSimplified(binder, self.recorded(binder), field)) continue;
            try self.unfold(binder, field);
            try kept.append(self.scratch, .{ .name = binder, .value = field });
        }
        return try self.builder.lets(kept.items, try self.term(alternative.body, continuation), span);
    }

    /// The constructor and fields `t` is known to be, when it is a saturated
    /// constructor application or a local recorded in `known`.
    fn knownConstructor(self: *Simplifier, t: core.Term) Error!?Constructed {
        if (try self.constructed(t)) |c| return c;
        return switch (t.kind) {
            .symbol => |id| self.known.get(id),
            else => null,
        };
    }

    /// The constructor and fields of `t`, when it is a saturated constructor
    /// application.
    fn constructed(self: *Simplifier, t: core.Term) Error!?Constructed {
        const id = switch (t.head().kind) {
            .symbol => |id| id,
            else => return null,
        };
        const constructor = self.env.datatypes.constructorOf(&self.env.interner, id) orelse return null;

        const fields = try self.scratch.alloc(core.Term, constructor.fields.len);
        var walk = t;
        var i = fields.len;
        while (walk.kind == .apply) : (walk = walk.kind.apply.function) {
            if (i == 0) return null;
            i -= 1;
            fields[i] = walk.kind.apply.argument;
        }
        if (i != 0) return null;
        return .{ .constructor = id, .fields = fields };
    }

    /// A copy of `name`'s unfolding, analysed, when a call to it under
    /// `continuation` inlines it.
    fn inlined(self: *Simplifier, name: core.SymbolId, continuation: []const Frame) Error!?core.Term {
        if (!self.options.call_site_inline) return null;
        const unfolding = self.unfoldings.get(name) orelse return null;
        if (self.phase == .laws and self.laws.names(name)) return null;
        const arity = unfolding.arity();
        if (appliedTo(continuation) < arity) return null;

        if (!self.env.alwaysInlines(name)) {
            const parameters = try self.scratch.alloc(core.SymbolId, arity);
            const known = try self.scratch.alloc(?cost.Known, arity);
            const body = unfolding.peel(parameters);
            for (known, continuation[0..arity]) |*argument_known, frame| {
                argument_known.* = try self.argumentKnown(frame.apply.operand.value());
            }
            const measured = cost.measure(body, parameters, known);
            if (measured.size > self.options.inline_threshold + measured.discount) return null;
        }

        var renamed: std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId) = .empty;
        return try self.analyser.analyse(try self.copy(unfolding, &renamed));
    }

    /// What an argument, not yet simplified, is known to be, looking through
    /// the substitution.
    fn argumentKnown(self: *Simplifier, argument: core.Term) Error!?cost.Known {
        var t = argument;
        while (t.kind == .symbol) t = (self.substitution.get(t.kind.symbol) orelse break).value();
        if (try self.knownConstructor(t)) |known| return .{ .constructor = known.constructor };
        return switch (t.kind) {
            .lambda => .lambda,
            .symbol => |id| if (self.unfoldings.get(id)) |unfolding|
                if (unfolding.kind == .lambda) .lambda else null
            else
                null,
            else => null,
        };
    }

    /// `t` with a fresh binder in place of each of its own.
    fn copy(
        self: *Simplifier,
        t: core.Term,
        renamed: *std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId),
    ) Error!core.Term {
        switch (t.kind) {
            .literal => return t,
            .symbol => |id| return if (renamed.get(id)) |new_id| self.builder.symbol(new_id, t.span) else t,
            .lambda => |lambda| {
                const parameter = try self.fresh(lambda.parameter, renamed);
                return try self.builder.lambda(parameter, try self.copy(lambda.body, renamed), t.span);
            },
            .apply => |apply| return try self.builder.apply(
                try self.copy(apply.function, renamed),
                try self.copy(apply.argument, renamed),
                t.span,
            ),
            .case => |case_term| {
                const scrutinee = try self.copy(case_term.scrutinee, renamed);
                const alternatives = try self.builder.slice(core.Case.Alternative, case_term.alternatives.len);
                for (case_term.alternatives, alternatives) |old, *new| new.* = try self.copyAlternative(old, renamed);
                const default = if (case_term.default) |body| try self.copy(body, renamed) else null;
                return try self.builder.caseWithDefault(scrutinee, alternatives, default, t.span);
            },
            .let => |let| {
                const value = try self.copy(let.value, renamed);
                const name = try self.fresh(let.name, renamed);
                return try self.builder.let(name, value, try self.copy(let.body, renamed), t.span);
            },
            .letrec => |letrec| {
                const bindings = try self.builder.slice(core.Letrec.Binding, letrec.bindings.len);
                for (letrec.bindings, bindings) |old, *new| new.name = try self.fresh(old.name, renamed);
                for (letrec.bindings, bindings) |old, *new| new.value = try self.copy(old.value, renamed);
                return try self.builder.letrec(bindings, try self.copy(letrec.body, renamed), t.span);
            },
        }
    }

    /// `alternative` with a fresh binder in place of each of its own.
    fn copyAlternative(
        self: *Simplifier,
        alternative: core.Case.Alternative,
        renamed: *std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId),
    ) Error!core.Case.Alternative {
        const binders = try self.builder.slice(core.SymbolId, alternative.binders.len);
        for (alternative.binders, binders) |binder, *new_binder| new_binder.* = try self.fresh(binder, renamed);
        return .{
            .constructor = alternative.constructor,
            .binders = binders,
            .body = try self.copy(alternative.body, renamed),
        };
    }

    fn fresh(
        self: *Simplifier,
        binder: core.SymbolId,
        renamed: *std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId),
    ) Error!core.SymbolId {
        const id = try self.env.interner.fresh(self.env.interner.spelling(binder));
        self.env.interner.setDetails(id, self.env.interner.details(binder));
        try renamed.put(self.scratch, binder, id);
        return id;
    }
};

/// How many application frames `continuation` opens with.
fn appliedTo(continuation: []const Frame) usize {
    for (continuation, 0..) |frame, i| {
        if (frame != .apply) return i;
    }
    return continuation.len;
}

/// Whether `t` is a value without being evaluated.
fn whnf(t: core.Term) bool {
    return t.kind == .literal or t.kind == .lambda;
}

/// Whether a binding used once may move to its occurrence.
fn movable(once: Occurrence.Once, value: core.Term) bool {
    return once.branches == 1 and (!once.inside_lambda or value.kind == .lambda);
}

const testing = std.testing;
const test_support = core.test_support;

const Simplified = struct { term: core.Term, changed: bool };

/// Analyse `t` and simplify it once. `scratch` must outlive the result.
fn simplifyOnce(pb: *test_support.ProgramBuilder, scratch: Allocator, options: Options, t: core.Term) !Simplified {
    const occurrences = try scratch.create(Table);
    occurrences.* = .init(scratch);
    const analyser = try scratch.create(Analyser);
    analyser.* = .{
        .scratch = scratch,
        .builder = pb.terms(),
        .env = &pb.env,
        .table = occurrences,
        .drop_dead = options.dead_bindings,
    };
    const analysed = try analyser.analyse(t);
    var simplifier: Simplifier = .init(analyser, &pb.env, options, .final);
    return .{ .term = try simplifier.simplify(analysed), .changed = simplifier.changed };
}

/// Analyse `t`, simplify it once, and print the result.
fn expectSimplifies(
    pb: *test_support.ProgramBuilder,
    expected: []const u8,
    changed: bool,
    t: core.Term,
) !void {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const simplified = try simplifyOnce(pb, scratch.allocator(), .{}, t);
    try test_support.expectPrints(pb, expected, simplified.term);
    try testing.expectEqual(changed, simplified.changed);
}

test "a term with no redex is unchanged" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const g = try pb.global("g");
    const x = try pb.local("x");
    try expectSimplifies(&pb, "\\x -> g x", false, try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{pb.symbol(x)})));
}

test "each copy of an inlined function binds fresh names" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const h = try pb.local("h");
    const y = try pb.local("y");
    const z = try pb.local("z");
    const value = try pb.lambda(&.{y}, try pb.let(
        z,
        try pb.apply(pb.symbol(f), &.{pb.symbol(y)}),
        try pb.apply(pb.symbol(g), &.{ pb.symbol(z), pb.symbol(z) }),
    ));
    const term = try pb.let(h, value, try pb.apply(pb.symbol(g), &.{
        try pb.apply(pb.symbol(h), &.{pb.number(1)}),
        try pb.apply(pb.symbol(h), &.{pb.number(2)}),
    }));

    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const simplified = try simplifyOnce(&pb, scratch.allocator(), .{}, term);

    var binders: std.ArrayList(core.SymbolId) = .empty;
    defer binders.deinit(testing.allocator);
    try collectBinders(simplified.term, &binders);
    try testing.expectEqual(5, binders.items.len);
    for (binders.items, 0..) |binder, i| {
        try testing.expect(std.mem.indexOfScalar(core.SymbolId, binders.items[i + 1 ..], binder) == null);
    }
}

fn collectBinders(t: core.Term, out: *std.ArrayList(core.SymbolId)) !void {
    switch (t.kind) {
        .symbol, .literal => {},
        .lambda => |lambda| {
            try out.append(testing.allocator, lambda.parameter);
            try collectBinders(lambda.body, out);
        },
        .apply => |apply| {
            try collectBinders(apply.function, out);
            try collectBinders(apply.argument, out);
        },
        .case => |case_term| {
            try collectBinders(case_term.scrutinee, out);
            for (case_term.alternatives) |alternative| {
                try out.appendSlice(testing.allocator, alternative.binders);
                try collectBinders(alternative.body, out);
            }
            if (case_term.default) |body| try collectBinders(body, out);
        },
        .let => |let| {
            try out.append(testing.allocator, let.name);
            try collectBinders(let.value, out);
            try collectBinders(let.body, out);
        },
        .letrec => |letrec| {
            for (letrec.bindings) |binding| {
                try out.append(testing.allocator, binding.name);
                try collectBinders(binding.value, out);
            }
            try collectBinders(letrec.body, out);
        },
    }
}

test "a simplified lambda applied to arguments is analysed again first" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    try pb.datatype("Box", &.{.{ "Box", &.{core.types.variable_type(0)} }});
    const box = try pb.global("Box");
    const g = try pb.global("g");
    const h = try pb.global("h");
    const f = try pb.local("f");
    const y = try pb.local("y");
    const z = try pb.local("z");

    // `case Box (\y -> let z = y in g z z) of Box f -> f (h 1)`. Simplifying
    // the field substitutes `z`, so `y`, recorded once, is used twice.
    const field = try pb.lambda(&.{y}, try pb.let(
        z,
        pb.symbol(y),
        try pb.apply(pb.symbol(g), &.{ pb.symbol(z), pb.symbol(z) }),
    ));
    const term = try pb.case(try pb.apply(pb.symbol(box), &.{field}), &.{
        .{ .constructor = box, .binders = &.{f}, .body = try pb.apply(pb.symbol(f), &.{
            try pb.apply(pb.symbol(h), &.{pb.number(1)}),
        }) },
    });
    try expectSimplifies(&pb,
        \\let y = h 1 in
        \\g y y
    , true, term);
}
