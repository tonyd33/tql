//! Core-to-Core rewrites over a checked program.
//!
//! Skipping this pass changes no observable result: every rewrite maps a term
//! onto another term the surface language can express, and the corpus is run
//! both ways. Desugaring stays literal so its goldens keep meaning one surface
//! form per Core term, and this is where algebraic laws live instead.
//!
//! Runs after inference, so a rewrite may assume its input type-checked.

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// Rewrite every definition in `program`, in place.
///
/// Terms are allocated from the program's own arena, so the rewritten program
/// owns its terms exactly as the desugared one did.
pub fn run(program: *core.Program) Error!void {
    const kleisli = program.env.interner.lookup("kleisli") orelse return;

    var pass: Pass = .{
        .builder = .{ .allocator = program.env.allocator() },
        .interner = &program.env.interner,
        .kleisli = kleisli,
    };

    const definitions = try program.env.allocator().alloc(
        core.Definition,
        program.definitions.len,
    );
    for (program.definitions, definitions) |old, *new| {
        new.* = .{
            .symbol = old.symbol,
            .body = try pass.term(old.body),
            .span = old.span,
        };
    }
    program.definitions = definitions;
}

// ============================================================================
//                              Tests
// ============================================================================

const grammar = @import("lang/grammar.zig");
const root = @import("root.zig");

/// Desugars and checks `query`, runs the pass, and renders `main`.
fn simplified(allocator: Allocator, query: []const u8, out: *std.Io.Writer.Allocating) !void {
    var grammars = grammar.Registry.init(allocator, &.{});
    defer grammars.deinit();
    const g = try grammars.get("typescript");

    var engine = try root.Engine.init(.{ .allocator = allocator, .io = undefined });
    defer engine.deinit();

    var sink = diagnostic.Sink.init(allocator);
    defer sink.deinit();

    var result = try engine.checkQuery(query, g, &sink);
    defer result.deinit();

    try run(&result);

    const printer: core.Printer = .{ .interner = &result.env.interner };
    for (result.entryDefinitions()) |definition| {
        try printer.term(definition.body, &out.writer);
    }
}

test "a kind test on a child axis fuses into the axis" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = children | of_kind :class_declaration;",
        &w,
    );
    try std.testing.expectEqualStrings("children_of_kind :class_declaration", w.written());
}

test "a kind test on a descendant axis fuses into the axis" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = descendants | of_kind :class_declaration;",
        &w,
    );
    try std.testing.expectEqualStrings("descendants_of_kind :class_declaration", w.written());
}

test "a kind test fuses under a surrounding composition" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = descendants | of_kind :class_declaration | .name;",
        &w,
    );
    try std.testing.expectEqualStrings(
        "kleisli (descendants_of_kind :class_declaration) field[name]",
        w.written(),
    );
}

test "a kind test fuses into an axis after an earlier stage" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = children | descendants | of_kind :class_declaration | .name;",
        &w,
    );
    try std.testing.expectEqualStrings(
        "kleisli (kleisli children (descendants_of_kind :class_declaration)) field[name]",
        w.written(),
    );
}

test "a kind test after an earlier non-axis stage is left alone" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = children | parent | of_kind :class_declaration;",
        &w,
    );
    try std.testing.expectEqualStrings(
        "kleisli (kleisli children parent) (of_kind :class_declaration)",
        w.written(),
    );
}

test "a kind test on a non-axis is left alone" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    // `parent` has no fused form, so the composition must survive.
    try simplified(
        std.testing.allocator,
        "main = parent | of_kind :class_declaration;",
        &w,
    );
    try std.testing.expectEqualStrings(
        "kleisli parent (of_kind :class_declaration)",
        w.written(),
    );
}

test "a kind test on a parameter fuses into the axis" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(
        std.testing.allocator,
        "main = (\\k -> descendants | of_kind k) :class_declaration;",
        &w,
    );
    try std.testing.expectEqualStrings(
        "(\\k -> descendants_of_kind k) :class_declaration",
        w.written(),
    );
}

test "an axis with no kind test is left alone" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try simplified(std.testing.allocator, "main = descendants | arr kind;", &w);
    try std.testing.expectEqualStrings("kleisli descendants (arr kind)", w.written());
}

const Pass = struct {
    builder: core.Builder,
    interner: *core.Interner,
    kleisli: core.SymbolId,

    /// Rewrite `t`, bottom up. A rewrite sees operands that are already
    /// rewritten, so one traversal reaches a fused axis nested in a fused axis.
    fn term(self: *Pass, t: core.Term) Error!core.Term {
        return switch (t.kind) {
            .symbol, .literal => t,
            .lambda => |l| try self.builder.lambda(
                l.parameter,
                try self.term(l.body),
                t.span,
            ),
            .apply => |a| try self.apply(
                try self.term(a.function),
                try self.term(a.argument),
                t.span,
            ),
            .case => |c| blk: {
                const alternatives = try self.builder.slice(
                    core.Case.Alternative,
                    c.alternatives.len,
                );
                for (c.alternatives, alternatives) |old, *new| {
                    new.* = .{
                        .constructor = old.constructor,
                        .binders = old.binders,
                        .body = try self.term(old.body),
                    };
                }
                break :blk try self.builder.case(
                    try self.term(c.scrutinee),
                    alternatives,
                    t.span,
                );
            },
            .letrec => |l| blk: {
                const bindings = try self.builder.slice(
                    core.Letrec.Binding,
                    l.bindings.len,
                );
                for (l.bindings, bindings) |old, *new| {
                    new.* = .{ .name = old.name, .value = try self.term(old.value) };
                }
                break :blk try self.builder.letrec(
                    bindings,
                    try self.term(l.body),
                    t.span,
                );
            },
            .bind => |b| try self.builder.bind(
                b.name,
                try self.term(b.value),
                try self.term(b.body),
                t.span,
            ),
        };
    }

    /// Rebuild an application, applying any law that matches it.
    fn apply(
        self: *Pass,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Error!core.Term {
        if (try self.fuseKindAxis(function, argument, span)) |fused| return fused;
        return try self.builder.apply(function, argument, span);
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
        self: *Pass,
        function: core.Term,
        argument: core.Term,
        span: diagnostic.Span,
    ) Error!?core.Term {
        const kind = self.kindTested(argument) orelse return null;
        const composed = self.kleisliOperand(function) orelse return null;

        switch (composed.kind) {
            .symbol => |axis| {
                const fused = self.fusedAxis(axis) orelse return null;
                return try self.builder.apply(self.builder.symbol(fused, span), kind, span);
            },
            .apply => |a| {
                const before = self.kleisliOperand(a.function) orelse return null;
                const axis = switch (a.argument.kind) {
                    .symbol => |id| id,
                    else => return null,
                };
                const fused = self.fusedAxis(axis) orelse return null;
                return try self.builder.applyMany(
                    self.builder.symbol(self.kleisli, span),
                    &.{ before, try self.builder.apply(self.builder.symbol(fused, span), kind, span) },
                    span,
                );
            },
            else => return null,
        }
    }

    /// `p`, when `t` is `kleisli p`.
    fn kleisliOperand(self: *const Pass, t: core.Term) ?core.Term {
        const a = switch (t.kind) {
            .apply => |a| a,
            else => return null,
        };
        if (a.function.kind != .symbol) return null;
        if (a.function.kind.symbol != self.kleisli) return null;
        return a.argument;
    }

    /// The primitive for `axis` with a kind test folded in, when `axis` has a
    /// fused form.
    fn fusedAxis(self: *const Pass, axis: core.SymbolId) ?core.SymbolId {
        const primop = self.primopOf(axis) orelse return null;
        const fused = primop.fusedWithKindTest() orelse return null;
        return self.interner.lookup(@tagName(fused));
    }

    /// `k`, when `t` is `of_kind k`.
    fn kindTested(self: *const Pass, t: core.Term) ?core.Term {
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
    fn primopOf(self: *const Pass, id: core.SymbolId) ?core.PrimOp {
        return switch (self.interner.details(id)) {
            .primop => |p| p,
            else => null,
        };
    }
};
