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

    /// The term a law rewrites `function argument` to, when one matches.
    ///
    /// Preconditions: `function` and `argument` are simplified.
    pub fn apply(
        self: *const Laws,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Allocator.Error!?core.Term {
        return try self.fuseKindAxis(function, argument, span);
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
        const kind = self.kindTested(argument) orelse return null;
        const composed = kleisliOperand(kleisli, function) orelse return null;

        switch (composed.kind) {
            .symbol => |axis| {
                const fused = self.fusedAxis(axis, kind) orelse return null;
                return try self.builder.apply(self.builder.symbol(fused, span), kind, span);
            },
            .apply => |a| {
                const before = kleisliOperand(kleisli, a.function) orelse return null;
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

    /// `k`, when `t` is `of_kind k`.
    fn kindTested(self: *const Laws, t: core.Term) ?core.Term {
        const a = switch (t.kind) {
            .apply => |a| a,
            else => return null,
        };
        const id = switch (a.function.kind) {
            .symbol => |s| s,
            else => return null,
        };
        if (self.primopOf(id) != .of_kind) return null;
        return a.argument;
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

/// `p`, when `t` is `kleisli p`.
fn kleisliOperand(kleisli: core.SymbolId, t: core.Term) ?core.Term {
    const a = switch (t.kind) {
        .apply => |a| a,
        else => return null,
    };
    if (a.function.kind != .symbol) return null;
    if (a.function.kind.symbol != kleisli) return null;
    return a.argument;
}
