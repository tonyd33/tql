//! One simplifying traversal of a definition: top down, carrying a
//! substitution and the arguments of the application being simplified.

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
    term: core.Term,
    span: diagnostic.Span,
};

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
/// - let from the head: `(let x = e in f) a` is `let x = e in f a`;
/// - a dead binding is dropped;
/// - a binding used once, in one branch, outside any lambda, or whose value
///   is a lambda, moves to its occurrence;
/// - a binding whose value is trivial is substituted everywhere;
/// - a `case` of a known constructor takes its alternative;
/// - a saturated call to a function with an unfolding small enough, or
///   marked to always inline, is replaced by a copy of the unfolding;
/// - the laws.
///
/// Binders are unique, so the substitution needs no scopes. A copied
/// unfolding gets a fresh binder for each of its own, and is analysed.
pub const Simplifier = struct {
    builder: core.Builder,
    /// Argument lists and the tables below.
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

    /// Simplify `t` applied to `arguments`, which are not yet simplified.
    fn term(self: *Simplifier, t: core.Term, arguments: []const Argument) Error!core.Term {
        switch (t.kind) {
            .literal => return try self.rebuild(t, arguments),
            .symbol => |id| {
                if (self.substitution.get(id)) |entry| return switch (entry) {
                    .suspended => |value| try self.term(value, arguments),
                    // Simplifying `value` may have outdated the records of
                    // the binders in it.
                    .done => |value| if (arguments.len == 0)
                        value
                    else
                        try self.term(try self.analyser.analyse(value), arguments),
                };
                if (try self.inlined(id, arguments)) |unfolded| {
                    self.changed = true;
                    return try self.term(unfolded, arguments);
                }
                return try self.rebuild(t, arguments);
            },
            .apply => {
                var spine: std.ArrayList(Argument) = .empty;
                var head = t;
                while (head.kind == .apply) : (head = head.kind.apply.function) {
                    try spine.append(self.scratch, .{ .term = head.kind.apply.argument, .span = head.span });
                }
                std.mem.reverse(Argument, spine.items);
                try spine.appendSlice(self.scratch, arguments);
                return try self.term(head, spine.items);
            },
            .lambda => |lambda| {
                if (arguments.len == 0 or !self.options.beta) {
                    const rebuilt = try self.builder.lambda(lambda.parameter, try self.term(lambda.body, &.{}), t.span);
                    return try self.rebuild(rebuilt, arguments);
                }
                self.changed = true;
                // Applied to fewer arguments than the chain takes, the
                // parameter's uses stay under the rest of the chain.
                const occurrence = self.recorded(lambda.parameter);
                const seen = if (arguments.len < t.arity()) occurrence.insideLambda() else occurrence;
                return try self.bind(lambda.parameter, seen, arguments[0].term, lambda.body, arguments[1..], t.span);
            },
            .let => |let| {
                if (arguments.len > 0 and !self.options.let_from_head) {
                    return try self.rebuild(try self.term(t, &.{}), arguments);
                }
                if (arguments.len > 0) self.changed = true;
                return try self.bind(let.name, self.recorded(let.name), let.value, let.body, arguments, t.span);
            },
            .letrec => |letrec| {
                if (arguments.len > 0 and !self.options.let_from_head) {
                    return try self.rebuild(try self.term(t, &.{}), arguments);
                }
                if (arguments.len > 0) self.changed = true;
                const bindings = try self.builder.slice(core.Letrec.Binding, letrec.bindings.len);
                for (letrec.bindings, bindings) |old, *new| {
                    new.* = .{ .name = old.name, .value = try self.term(old.value, &.{}) };
                    try self.unfold(new.name, new.value);
                }
                return try self.builder.letrec(bindings, try self.term(letrec.body, arguments), t.span);
            },
            .case => |case_term| return try self.case(case_term, arguments, t.span),
        }
    }

    /// Apply `head` to `arguments`, simplifying each and trying the laws at
    /// every application.
    fn rebuild(self: *Simplifier, head: core.Term, arguments: []const Argument) Error!core.Term {
        var result = head;
        for (arguments) |argument| {
            const operand = try self.term(argument.term, &.{});
            const law = if (self.options.laws) try self.laws.apply(result, operand, argument.span) else null;
            if (law) |rewritten| {
                self.changed = true;
                result = rewritten;
            } else {
                result = try self.builder.apply(result, operand, argument.span);
            }
        }
        return result;
    }

    /// Simplify `body` applied to `arguments` with `name`, used as
    /// `occurrence` says, bound to `value`, which is not yet simplified.
    fn bind(
        self: *Simplifier,
        name: core.SymbolId,
        occurrence: Occurrence,
        value: core.Term,
        body: core.Term,
        arguments: []const Argument,
        span: diagnostic.Span,
    ) Error!core.Term {
        switch (occurrence) {
            .dead => if (self.options.dead_bindings) {
                self.changed = true;
                return try self.term(body, arguments);
            },
            .once => |once| if (self.options.pre_inline and movable(once, value)) {
                self.changed = true;
                try self.substitution.put(name, .{ .suspended = value });
                return try self.term(body, arguments);
            },
            .many, .loop_breaker => {},
        }

        const simplified = try self.term(value, &.{});
        if (!try self.bindSimplified(name, occurrence, simplified)) return try self.term(body, arguments);
        try self.unfold(name, simplified);
        return try self.builder.let(name, simplified, try self.term(body, arguments), span);
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

    fn case(
        self: *Simplifier,
        case_term: *const core.Case,
        arguments: []const Argument,
        span: diagnostic.Span,
    ) Error!core.Term {
        var scrutinee = try self.term(case_term.scrutinee, &.{});
        var case_alternatives = case_term.alternatives;
        const default = case_term.default;
        if (self.options.laws and default == null) {
            if (self.laws.foldComparison(scrutinee, case_alternatives)) |folded| {
                self.changed = true;
                const call = try self.builder.applyMany(self.builder.symbol(folded.comparison, scrutinee.span), &.{ folded.left, folded.right }, span);
                return try self.rebuild(call, arguments);
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
                return try self.select(alternative, known_constructor.fields, arguments, span);
            }
        }
        const evaluated = known != null or (self.options.case_of_known_constructor and whnf(scrutinee));
        if (default) |body| {
            if (evaluated) {
                self.changed = true;
                return try self.rebuild(try self.term(body, &.{}), arguments);
            }
        }

        const alternatives = try self.builder.slice(core.Case.Alternative, case_alternatives.len);
        for (case_alternatives, alternatives) |old, *new| {
            new.* = .{
                .constructor = old.constructor,
                .binders = old.binders,
                .body = try self.term(old.body, &.{}),
            };
        }
        const simplified_default = if (default) |body| try self.term(body, &.{}) else null;
        return try self.rebuild(try self.builder.caseWithDefault(scrutinee, alternatives, simplified_default, span), arguments);
    }

    /// Take `alternative` with its binders bound to `fields`.
    fn select(
        self: *Simplifier,
        alternative: core.Case.Alternative,
        fields: []const core.Term,
        arguments: []const Argument,
        span: diagnostic.Span,
    ) Error!core.Term {
        const kept = try self.scratch.alloc(bool, fields.len);
        for (alternative.binders, fields, kept) |binder, field, *keep| {
            keep.* = try self.bindSimplified(binder, self.recorded(binder), field);
            if (keep.*) try self.unfold(binder, field);
        }

        var result = try self.term(alternative.body, arguments);
        var i = fields.len;
        while (i > 0) {
            i -= 1;
            if (kept[i]) result = try self.builder.let(alternative.binders[i], fields[i], result, span);
        }
        return result;
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

    /// A copy of `name`'s unfolding, analysed, when a call to it with
    /// `arguments` inlines it.
    fn inlined(self: *Simplifier, name: core.SymbolId, arguments: []const Argument) Error!?core.Term {
        if (!self.options.call_site_inline) return null;
        const unfolding = self.unfoldings.get(name) orelse return null;
        if (self.phase == .laws and self.laws.names(name)) return null;
        const arity = unfolding.arity();
        if (arguments.len < arity) return null;

        if (!self.env.alwaysInlines(name)) {
            const parameters = try self.scratch.alloc(core.SymbolId, arity);
            const known = try self.scratch.alloc(?cost.Known, arity);
            var body = unfolding;
            for (parameters, known, arguments[0..arity]) |*parameter, *argument_known, argument| {
                parameter.* = body.kind.lambda.parameter;
                body = body.kind.lambda.body;
                argument_known.* = try self.argumentKnown(argument.term);
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
                for (case_term.alternatives, alternatives) |old, *new| {
                    const binders = try self.builder.slice(core.SymbolId, old.binders.len);
                    for (old.binders, binders) |binder, *new_binder| new_binder.* = try self.fresh(binder, renamed);
                    new.* = .{
                        .constructor = old.constructor,
                        .binders = binders,
                        .body = try self.copy(old.body, renamed),
                    };
                }
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

    fn fresh(
        self: *Simplifier,
        binder: core.SymbolId,
        renamed: *std.AutoHashMapUnmanaged(core.SymbolId, core.SymbolId),
    ) Error!core.SymbolId {
        const id = try self.env.interner.fresh(self.env.interner.spelling(binder));
        try renamed.put(self.scratch, binder, id);
        return id;
    }
};

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
