//! One simplifying traversal of a definition: top down, carrying a
//! substitution and the arguments of the application being simplified.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const Laws = @import("laws.zig").Laws;

const Allocator = std.mem.Allocator;
const Occurrence = core.occurrence.Occurrence;

pub const Error = Allocator.Error;

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
/// - the laws.
///
/// Binders are unique, so the substitution needs no scopes. Nothing here
/// copies a term that binds a name.
pub const Simplifier = struct {
    builder: core.Builder,
    /// Argument lists and the tables below.
    scratch: Allocator,
    interner: *const core.Interner,
    datatypes: *const core.datatypes.Registry,
    occurrences: *const core.occurrence.Table,
    laws: Laws,
    substitution: core.SymbolTable(Substitution),
    /// Locals bound to a constructor of trivial arguments.
    known: core.SymbolTable(Constructed),
    /// Whether a rewrite fired.
    changed: bool = false,

    pub fn init(
        builder: core.Builder,
        scratch: Allocator,
        env: *const core.env.Env,
        occurrences: *const core.occurrence.Table,
    ) Simplifier {
        return .{
            .builder = builder,
            .scratch = scratch,
            .interner = &env.interner,
            .datatypes = &env.datatypes,
            .occurrences = occurrences,
            .laws = .{
                .builder = builder,
                .interner = &env.interner,
                .primitives = &env.primitives,
                .kleisli = env.interner.lookup(.prelude, "kleisli"),
            },
            .substitution = .init(scratch),
            .known = .init(scratch),
        };
    }

    pub fn simplify(self: *Simplifier, t: core.Term) Error!core.Term {
        return try self.term(t, &.{});
    }

    /// Simplify `t` applied to `arguments`, which are not yet simplified.
    fn term(self: *Simplifier, t: core.Term, arguments: []const Argument) Error!core.Term {
        switch (t.kind) {
            .literal => return try self.rebuild(t, arguments),
            .symbol => |id| {
                const entry = self.substitution.get(id) orelse return try self.rebuild(t, arguments);
                return switch (entry) {
                    .suspended => |value| try self.term(value, arguments),
                    .done => |value| if (arguments.len == 0) value else try self.term(value, arguments),
                };
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
                if (arguments.len == 0) {
                    return try self.builder.lambda(lambda.parameter, try self.term(lambda.body, &.{}), t.span);
                }
                self.changed = true;
                return try self.bind(lambda.parameter, arguments[0].term, lambda.body, arguments[1..], t.span);
            },
            .let => |let| {
                if (arguments.len > 0) self.changed = true;
                return try self.bind(let.name, let.value, let.body, arguments, t.span);
            },
            .letrec => |letrec| {
                if (arguments.len > 0) self.changed = true;
                const bindings = try self.builder.slice(core.Letrec.Binding, letrec.bindings.len);
                for (letrec.bindings, bindings) |old, *new| {
                    new.* = .{ .name = old.name, .value = try self.term(old.value, &.{}) };
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
            if (try self.laws.apply(result, operand, argument.span)) |rewritten| {
                self.changed = true;
                result = rewritten;
            } else {
                result = try self.builder.apply(result, operand, argument.span);
            }
        }
        return result;
    }

    /// Simplify `body` applied to `arguments` with `name` bound to `value`,
    /// which is not yet simplified.
    fn bind(
        self: *Simplifier,
        name: core.SymbolId,
        value: core.Term,
        body: core.Term,
        arguments: []const Argument,
        span: diagnostic.Span,
    ) Error!core.Term {
        switch (self.occurrences.get(name).?) {
            .dead => {
                self.changed = true;
                return try self.term(body, arguments);
            },
            .once => |once| if (movable(once, value)) {
                self.changed = true;
                try self.substitution.put(name, .{ .suspended = value });
                return try self.term(body, arguments);
            },
            .many, .loop_breaker => {},
        }

        const simplified = try self.term(value, &.{});
        if (!try self.bindSimplified(name, simplified)) return try self.term(body, arguments);
        return try self.builder.let(name, simplified, try self.term(body, arguments), span);
    }

    /// Bind `name` to `value`, already simplified, by substitution when it may
    /// be. Returns whether `name` must still be bound by a `let`.
    fn bindSimplified(self: *Simplifier, name: core.SymbolId, value: core.Term) Error!bool {
        const substituted = switch (self.occurrences.get(name).?) {
            .dead => true,
            .once => |once| movable(once, value) or trivial(value),
            .many, .loop_breaker => trivial(value),
        };
        if (substituted) {
            self.changed = true;
            try self.substitution.put(name, .{ .done = value });
            return false;
        }
        if (try self.constructed(value)) |c| {
            for (c.fields) |field| if (!trivial(field)) return true;
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
        const scrutinee = try self.term(case_term.scrutinee, &.{});
        if (try self.knownConstructor(scrutinee)) |known| {
            for (case_term.alternatives) |alternative| {
                if (alternative.constructor != known.constructor) continue;
                self.changed = true;
                return try self.select(alternative, known.fields, arguments, span);
            }
        }

        const alternatives = try self.builder.slice(core.Case.Alternative, case_term.alternatives.len);
        for (case_term.alternatives, alternatives) |old, *new| {
            new.* = .{
                .constructor = old.constructor,
                .binders = old.binders,
                .body = try self.term(old.body, &.{}),
            };
        }
        return try self.rebuild(try self.builder.case(scrutinee, alternatives, span), arguments);
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
            keep.* = try self.bindSimplified(binder, field);
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
        var head = t;
        var count: usize = 0;
        while (head.kind == .apply) : (head = head.kind.apply.function) count += 1;
        const id = switch (head.kind) {
            .symbol => |id| id,
            else => return null,
        };
        const constructor = self.datatypes.constructorOf(self.interner, id) orelse return null;
        if (constructor.fields.len != count) return null;

        const fields = try self.scratch.alloc(core.Term, count);
        var walk = t;
        var i = count;
        while (i > 0) : (walk = walk.kind.apply.function) {
            i -= 1;
            fields[i] = walk.kind.apply.argument;
        }
        return .{ .constructor = id, .fields = fields };
    }
};

/// Whether a binding used once may move to its occurrence.
fn movable(once: Occurrence.Once, value: core.Term) bool {
    return once.branches == 1 and (!once.inside_lambda or value.kind == .lambda);
}

/// Whether copying `t` costs nothing.
fn trivial(t: core.Term) bool {
    return switch (t.kind) {
        .symbol => true,
        .literal => |value| value == .number or value == .kind,
        else => false,
    };
}

const testing = std.testing;
const test_support = core.test_support;

/// Analyse `t`, simplify it once, and print the result.
fn expectSimplifies(
    pb: *test_support.ProgramBuilder,
    expected: []const u8,
    changed: bool,
    t: core.Term,
) !void {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    var occurrences: core.occurrence.Table = .init(scratch.allocator());
    var analyser: core.occurrence.Analyser = .{
        .scratch = scratch.allocator(),
        .builder = pb.terms(),
        .interner = &pb.env.interner,
        .table = &occurrences,
    };
    const analysed = try analyser.analyse(t);
    var simplifier: Simplifier = .init(pb.terms(), scratch.allocator(), &pb.env, &occurrences);
    const simplified = try simplifier.simplify(analysed);

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    const printer: core.Printer = .{ .interner = &pb.env.interner };
    try printer.term(simplified, &w.writer);
    try testing.expectEqualStrings(expected, w.written());
    try testing.expectEqual(changed, simplifier.changed);
}

test "a dead argument is dropped" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const x = try pb.local("x");
    const term = try pb.apply(try pb.lambda(&.{x}, pb.number(1)), &.{try pb.apply(pb.symbol(f), &.{pb.number(2)})});
    try expectSimplifies(&pb, "1", true, term);
}

test "an argument used once moves to its occurrence" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const term = try pb.apply(
        try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{pb.symbol(x)})),
        &.{try pb.apply(pb.symbol(f), &.{pb.number(2)})},
    );
    try expectSimplifies(&pb, "g (f 2)", true, term);
}

test "an argument used under a lambda is bound by a let" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const y = try pb.local("y");
    const term = try pb.apply(
        try pb.lambda(&.{ x, y }, try pb.apply(pb.symbol(g), &.{ pb.symbol(x), pb.symbol(y) })),
        &.{try pb.apply(pb.symbol(f), &.{pb.number(2)})},
    );
    try expectSimplifies(&pb,
        \\let x = f 2 in
        \\\y -> g x y
    , true, term);
}

test "a trivial argument is substituted at every occurrence" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const g = try pb.global("g");
    const x = try pb.local("x");
    const term = try pb.apply(
        try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{ pb.symbol(x), pb.symbol(x) })),
        &.{pb.number(1)},
    );
    try expectSimplifies(&pb, "g 1 1", true, term);
}

test "a compound argument used twice is bound by a let" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const term = try pb.apply(
        try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{ pb.symbol(x), pb.symbol(x) })),
        &.{try pb.apply(pb.symbol(f), &.{pb.number(2)})},
    );
    try expectSimplifies(&pb,
        \\let x = f 2 in
        \\g x x
    , true, term);
}

test "a lambda used once under a lambda moves" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const h = try pb.local("h");
    const y = try pb.local("y");
    const z = try pb.local("z");
    const term = try pb.let(
        h,
        try pb.lambda(&.{y}, try pb.apply(pb.symbol(f), &.{pb.symbol(y)})),
        try pb.lambda(&.{z}, try pb.apply(pb.symbol(h), &.{pb.symbol(z)})),
    );
    try expectSimplifies(&pb, "\\z -> f z", true, term);
}

test "beta reduces a whole spine" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const g = try pb.global("g");
    const a = try pb.global("a");
    const b = try pb.global("b");
    const x = try pb.local("x");
    const y = try pb.local("y");
    const term = try pb.apply(
        try pb.lambda(&.{ x, y }, try pb.apply(pb.symbol(g), &.{ pb.symbol(x), pb.symbol(y) })),
        &.{ pb.symbol(a), pb.symbol(b) },
    );
    try expectSimplifies(&pb, "g a b", true, term);
}

test "an argument passes into the body of a let" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const f = try pb.global("f");
    const g = try pb.global("g");
    const k = try pb.local("k");
    const x = try pb.local("x");
    const term = try pb.apply(try pb.let(
        k,
        try pb.apply(pb.symbol(f), &.{pb.number(1)}),
        try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{ pb.symbol(k), pb.symbol(k), pb.symbol(x) })),
    ), &.{pb.number(2)});
    try expectSimplifies(&pb,
        \\let k = f 1 in
        \\g k k 2
    , true, term);
}

test "a case of a saturated constructor takes its alternative" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const h = try pb.local("h");
    const t = try pb.local("t");
    const term = try pb.case(try pb.apply(pb.symbol(cons), &.{ pb.number(1), pb.symbol(nil) }), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = pb.symbol(h) },
    });
    try expectSimplifies(&pb, "1", true, term);
}

test "a case of a nullary constructor takes its alternative" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const false_ = try pb.global("False");
    const true_ = try pb.global("True");
    const term = try pb.case(pb.symbol(true_), &.{
        .{ .constructor = false_, .binders = &.{}, .body = pb.number(2) },
        .{ .constructor = true_, .binders = &.{}, .body = pb.number(1) },
    });
    try expectSimplifies(&pb, "1", true, term);
}

test "a case of a local bound to a constructor of trivial arguments takes its alternative" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const p = try pb.local("p");
    const h = try pb.local("h");
    const t = try pb.local("t");
    const scrutinized = try pb.case(pb.symbol(p), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = pb.symbol(h) },
    });
    const term = try pb.lambda(&.{x}, try pb.let(
        p,
        try pb.apply(pb.symbol(cons), &.{ pb.symbol(x), pb.symbol(nil) }),
        try pb.apply(pb.symbol(g), &.{ pb.symbol(p), scrutinized }),
    ));
    try expectSimplifies(&pb,
        \\\x ->
        \\  let p = Cons x Nil in
        \\  g p x
    , true, term);
}

test "a local bound to a constructor with a compound argument is not a known constructor" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const f = try pb.global("f");
    const g = try pb.global("g");
    const x = try pb.local("x");
    const p = try pb.local("p");
    const h = try pb.local("h");
    const t = try pb.local("t");
    const scrutinized = try pb.case(pb.symbol(p), &.{
        .{ .constructor = nil, .binders = &.{}, .body = pb.number(0) },
        .{ .constructor = cons, .binders = &.{ h, t }, .body = pb.symbol(h) },
    });
    const term = try pb.lambda(&.{x}, try pb.let(
        p,
        try pb.apply(pb.symbol(cons), &.{ try pb.apply(pb.symbol(f), &.{pb.symbol(x)}), pb.symbol(nil) }),
        try pb.apply(pb.symbol(g), &.{ pb.symbol(p), scrutinized }),
    ));
    try expectSimplifies(&pb,
        \\\x ->
        \\  let p = Cons (f x) Nil in
        \\  g p (
        \\    case p of
        \\      Nil -> 0
        \\      Cons h t -> h
        \\  )
    , false, term);
}

test "a case with no alternative for a known constructor is left alone" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const nil = try pb.global("Nil");
    const cons = try pb.global("Cons");
    const h = try pb.local("h");
    const t = try pb.local("t");
    const term = try pb.case(pb.symbol(nil), &.{
        .{ .constructor = cons, .binders = &.{ h, t }, .body = pb.symbol(h) },
    });
    try expectSimplifies(&pb,
        \\case Nil of
        \\  Cons h t -> h
    , false, term);
}

test "a term with no redex is unchanged" {
    var pb = try test_support.ProgramBuilder.init(testing.allocator);
    defer pb.deinit();
    const g = try pb.global("g");
    const x = try pb.local("x");
    try expectSimplifies(&pb, "\\x -> g x", false, try pb.lambda(&.{x}, try pb.apply(pb.symbol(g), &.{pb.symbol(x)})));
}
