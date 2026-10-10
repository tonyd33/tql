//! Rewrites the language's meaning justifies and the calculus does not.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");

const Allocator = std.mem.Allocator;

pub const Laws = struct {
    builder: core.Builder,
    interner: *const core.Interner,
    classes: *const core.classes.Registry,
    primitives: *const std.EnumArray(core.PrimOp, ?core.SymbolId),
    /// A key is null when the library has none.
    known: *const std.EnumArray(core.Known, ?core.SymbolId),
    nil: core.SymbolId,
    false_: core.SymbolId,
    true_: core.SymbolId,
    /// `LT`, `EQ` and `GT`.
    ordering: [3]core.SymbolId,

    /// The library definitions a law matches on.
    const named = [_]core.Known{ .kleisli, .concat_map, .of_kind };

    /// Whether a law matches on `symbol`.
    pub fn names(self: *const Laws, symbol: core.SymbolId) bool {
        return switch (self.interner.details(symbol)) {
            .method, .instance => true,
            else => for (named) |key| {
                if (self.known.get(key) == symbol) break true;
            } else false,
        };
    }

    /// The term a law rewrites `function argument` to, when one matches.
    ///
    /// Preconditions: `function` and `argument` are simplified.
    pub fn apply(
        self: *const Laws,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Term {
        if (try self.fuseKindAxis(function, argument, span)) |fused| return fused;
        if (try self.selectKnownMethod(function, argument, span)) |selected| return selected;
        return try self.fuseKindBind(function, argument, span);
    }

    /// Applies `result` to the arguments of `t`'s spine, in order.
    fn spine(self: *const Laws, t: core.Term, result: *core.Term, span: diagnostic.Span) Allocator.Error!void {
        if (t.kind != .apply) return;
        try self.spine(t.kind.apply.function, result, span);
        result.* = try self.builder.apply(result.*, t.kind.apply.argument, span);
    }

    /// `m (instance[C,T] d_1 .. d_n)` becomes `m[T] d_1 .. d_n`, when `m` is a
    /// method of `C` and `d_1 .. d_n` is the evidence for each constraint of
    /// the instance's context with a dictionary. `m (dict[C] s_1 .. f_1 ..)`,
    /// a dictionary built in place, becomes the field `m` selects.
    fn selectKnownMethod(
        self: *const Laws,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Term {
        if (function.kind != .symbol) return null;
        const method = switch (self.interner.details(function.kind.symbol)) {
            .method => |m| m,
            else => return null,
        };
        const head = argument.head();
        if (head.kind != .symbol) return null;
        const class = self.classes.get(method.class);
        if (class.constructor == head.kind.symbol) {
            return spineArgument(argument, class.selectors.len + class.methods.len, class.selectors.len + method.index);
        }
        const instance = switch (self.interner.details(head.kind.symbol)) {
            .instance => |id| self.classes.instance(id),
            else => return null,
        };
        if (instance.class != method.class) return null;

        if (argument.spineLength() != self.classes.dictionaryCount(instance.context)) return null;
        var result = self.builder.symbol(instance.methods[method.index], span);
        try self.spine(argument, &result, span);
        return result;
    }

    /// A comparison of `left` and `right` that answers what a `case` makes of
    /// another one.
    pub const Folded = struct {
        comparison: core.SymbolId,
        left: core.Term,
        right: core.Term,
    };

    /// A `case` that maps a comparison's result to `True` and `False` is the
    /// comparison that returns that `Bool`:
    /// `case %compare_int a b of { LT -> True; EQ -> False; GT -> False }` is
    /// `%lt_int a b`, and `case %eq_int a b of { False -> True; True -> False }`
    /// is `%ne_int a b`.
    ///
    /// Preconditions: `scrutinee` is simplified.
    pub fn foldComparison(
        self: *const Laws,
        scrutinee: core.Term,
        alternatives: []const core.Case.Alternative,
    ) ?Folded {
        const outer = switch (scrutinee.kind) {
            .apply => |a| a,
            else => return null,
        };
        const inner = switch (outer.function.kind) {
            .apply => |a| a,
            else => return null,
        };
        const compared = switch (inner.function.kind) {
            .symbol => |id| (self.primopOf(id) orelse return null).compared() orelse return null,
            else => return null,
        };

        var wanted: [3]bool = undefined;
        if (compared.comparison == .compare) {
            for (&wanted, self.ordering) |*slot, constructor| {
                slot.* = self.answer(alternatives, constructor) orelse return null;
            }
        } else {
            const answers = compared.comparison.answers().?;
            const if_false = self.answer(alternatives, self.false_) orelse return null;
            const if_true = self.answer(alternatives, self.true_) orelse return null;
            for (&wanted, answers) |*slot, given| slot.* = if (given) if_true else if_false;
        }
        const comparison = core.Comparison.answering(wanted) orelse return null;
        const primop = core.PrimOp.comparing(comparison, compared.operands) orelse return null;
        return .{
            .comparison = self.primitives.get(primop) orelse return null,
            .left = inner.argument,
            .right = outer.argument,
        };
    }

    /// The `Bool` the alternative for `constructor` returns, when it binds
    /// nothing and returns a constant.
    fn answer(self: *const Laws, alternatives: []const core.Case.Alternative, constructor: core.SymbolId) ?bool {
        const alternative = alternativeFor(alternatives, constructor) orelse return null;
        if (alternative.binders.len > 0) return null;
        if (isSymbol(alternative.body, self.true_)) return true;
        if (isSymbol(alternative.body, self.false_)) return false;
        return null;
    }

    /// `kleisli <axis> (of_kind k)` becomes the axis that yields only `k`.
    ///
    /// Both spellings are writable by hand and denote the same list, so this
    /// removes the intermediate list without changing what the query means.
    /// `k` need not be a literal.
    ///
    /// `|` associates left, so an axis after an earlier stage arrives as
    /// `kleisli (kleisli p <axis>) (of_kind k)`. That is
    /// `kleisli p (kleisli <axis> (of_kind k))`, and becomes `kleisli p` of the
    /// fused axis.
    fn fuseKindAxis(
        self: *const Laws,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Term {
        const kleisli = self.known.get(.kleisli) orelse return null;
        const kind = operandOf(self.known.get(.of_kind) orelse return null, argument) orelse return null;
        const composed = operandOf(kleisli, function) orelse return null;

        switch (composed.kind) {
            .symbol => |axis| {
                const fused = self.fusedAxis(axis, kind) orelse return null;
                return try self.builder.apply(self.builder.symbol(fused, span), kind, span);
            },
            .apply => |a| {
                const before = operandOf(kleisli, a.function) orelse return null;
                const axis = switch (a.argument.kind) {
                    .symbol => |id| id,
                    else => return null,
                };
                const fused = self.fusedAxis(axis, kind) orelse return null;
                return try self.builder.applyMany(
                    self.builder.symbol(kleisli, span),
                    &.{ before, try self.builder.apply(self.builder.symbol(fused, span), kind, span) },
                    span,
                );
            },
            else => return null,
        }
    }

    /// `concat_map (\s -> case is_kind k s of { False -> Nil; True -> body })
    /// (axis r)` becomes `concat_map (\s -> body) (axis_of_kind k r)`. Returns
    /// null unless `k` does not read `s` and `fusedAxis` fuses `k` onto `axis`.
    fn fuseKindBind(
        self: *const Laws,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Term {
        const concat_map = self.known.get(.concat_map) orelse return null;
        const mapped = operandOf(concat_map, function) orelse return null;
        const lambda = switch (mapped.kind) {
            .lambda => |l| l,
            else => return null,
        };
        const walk = switch (argument.kind) {
            .apply => |a| a,
            else => return null,
        };
        const axis = switch (walk.function.kind) {
            .symbol => |id| id,
            else => return null,
        };
        const matched = switch (lambda.body.kind) {
            .case => |c| c,
            else => return null,
        };

        const s = lambda.parameter;
        const tested = self.kindTest(matched.scrutinee) orelse return null;
        if (!isSymbol(tested.subject, s)) return null;
        if (core.free.occurs(tested.kind, s)) return null;
        const fused = self.fusedAxis(axis, tested.kind) orelse return null;

        const failed = alternativeFor(matched.alternatives, self.false_) orelse return null;
        if (!isSymbol(failed.body, self.nil)) return null;
        const passed = alternativeFor(matched.alternatives, self.true_) orelse return null;

        return try self.builder.applyMany(
            self.builder.symbol(concat_map, span),
            &.{
                try self.builder.lambda(s, passed.body, mapped.span),
                try self.builder.applyMany(self.builder.symbol(fused, walk.function.span), &.{ tested.kind, walk.argument }, argument.span),
            },
            span,
        );
    }

    /// The primitive for `axis` with a test for `kind` folded in, when `axis`
    /// has a fused form.
    ///
    /// A `kind` that is not a literal may be anonymous, and fuses only onto
    /// `children` and `descendants`.
    fn fusedAxis(self: *const Laws, axis: core.SymbolId, kind: core.Term) ?core.SymbolId {
        const primop = self.primopOf(axis) orelse return null;
        if (kind.kind != .literal and (primop == .named_children or primop == .named_descendants)) return null;
        const fused = primop.fusedWithKindTest() orelse return null;
        return self.primitives.get(fused);
    }

    const KindTest = struct { kind: core.Term, subject: core.Term };

    /// `k` and `x`, when `t` is `is_kind k x`.
    fn kindTest(self: *const Laws, t: core.Term) ?KindTest {
        const a = switch (t.kind) {
            .apply => |a| a,
            else => return null,
        };
        const kind = operandOf(self.primitives.get(.is_kind) orelse return null, a.function) orelse return null;
        return .{ .kind = kind, .subject = a.argument };
    }

    /// The primitive a symbol names, when it names one. A local binding that
    /// shadows the name is a different symbol, so this cannot confuse the two.
    fn primopOf(self: *const Laws, id: core.SymbolId) ?core.PrimOp {
        return switch (self.interner.details(id)) {
            .primop => |p| p,
            else => null,
        };
    }
};

/// Argument `index` of `t`, when `t` is a head applied to `count` arguments.
fn spineArgument(t: core.Term, count: usize, index: usize) ?core.Term {
    if (t.spineLength() != count) return null;
    var current = t;
    for (0..count - 1 - index) |_| current = current.kind.apply.function;
    return current.kind.apply.argument;
}

/// `p`, when `t` is `head p`.
fn operandOf(head: core.SymbolId, t: core.Term) ?core.Term {
    const a = switch (t.kind) {
        .apply => |a| a,
        else => return null,
    };
    if (!isSymbol(a.function, head)) return null;
    return a.argument;
}

fn isSymbol(t: core.Term, id: core.SymbolId) bool {
    return t.kind == .symbol and t.kind.symbol == id;
}

/// The alternative for `constructor`, if there is one.
fn alternativeFor(alternatives: []const core.Case.Alternative, constructor: core.SymbolId) ?core.Case.Alternative {
    for (alternatives) |alternative| {
        if (alternative.constructor == constructor) return alternative;
    }
    return null;
}
