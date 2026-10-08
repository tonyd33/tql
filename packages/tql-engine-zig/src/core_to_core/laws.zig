//! Rewrites the language's meaning justifies and the calculus does not.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");

const Allocator = std.mem.Allocator;

pub const Laws = struct {
    builder: core.Builder,
    interner: *const core.Interner,
    primitives: *const std.EnumArray(core.PrimOp, ?core.SymbolId),
    /// Null when the prelude has none.
    kleisli: ?core.SymbolId,
    /// Null when the prelude has none.
    concat_map: ?core.SymbolId,
    nil: core.SymbolId,
    cons: core.SymbolId,
    false_: core.SymbolId,
    true_: core.SymbolId,

    /// Whether a law matches on `symbol`.
    pub fn names(self: *const Laws, symbol: core.SymbolId) bool {
        return symbol == self.kleisli or symbol == self.concat_map;
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
        return try self.fuseKindBind(function, argument, span);
    }

    /// `case of_kind k x of { Nil -> a; Cons n t -> b }` becomes
    /// `case is_kind k x of { False -> a; True -> let n = x in let t = Nil in b }`.
    /// Returns null unless `x` is a symbol.
    ///
    /// Preconditions: `scrutinee` is simplified.
    /// Postconditions: the result's scrutinee is simplified and its
    /// alternatives are not.
    pub fn rewriteCase(
        self: *const Laws,
        scrutinee: core.Term,
        alternatives: []const core.Case.Alternative,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Case {
        const tested = self.kindTest(.of_kind, scrutinee) orelse return null;
        if (tested.subject.kind != .symbol) return null;
        const is_kind = self.primitives.get(.is_kind) orelse return null;
        const nil = alternativeFor(alternatives, self.nil) orelse return null;
        const cons = alternativeFor(alternatives, self.cons) orelse return null;

        const b = self.builder;
        const tail = try b.let(cons.binders[1], b.symbol(self.nil, span), cons.body, span);
        return .{
            .scrutinee = try b.applyMany(b.symbol(is_kind, scrutinee.span), &.{ tested.kind, tested.subject }, scrutinee.span),
            .alternatives = try b.dupeSlice(core.Case.Alternative, &.{
                .{ .constructor = self.false_, .binders = &.{}, .body = nil.body },
                .{ .constructor = self.true_, .binders = &.{}, .body = try b.let(cons.binders[0], tested.subject, tail, span) },
            }),
        };
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
        const kleisli = self.kleisli orelse return null;
        const kind = self.kindTested(.of_kind, argument) orelse return null;
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
        const concat_map = self.concat_map orelse return null;
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
        const tested = self.kindTest(.is_kind, matched.scrutinee) orelse return null;
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

    /// `k`, when `t` is `primop k`.
    fn kindTested(self: *const Laws, primop: core.PrimOp, t: core.Term) ?core.Term {
        return operandOf(self.primitives.get(primop) orelse return null, t);
    }

    const KindTest = struct { kind: core.Term, subject: core.Term };

    /// `k` and `x`, when `t` is `primop k x`.
    fn kindTest(self: *const Laws, primop: core.PrimOp, t: core.Term) ?KindTest {
        const a = switch (t.kind) {
            .apply => |a| a,
            else => return null,
        };
        const kind = self.kindTested(primop, a.function) orelse return null;
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
