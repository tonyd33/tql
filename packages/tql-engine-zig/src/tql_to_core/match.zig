//! Patterns to flat Core `case`, for `case` alternatives and `do` binds.
//!
//! Compiles to a decision tree. A row is the patterns its alternative still
//! has to match, each against an occurrence, in the order they are written,
//! and the first remaining row decides the next step. A constructor test
//! splits over every constructor of the occurrence's datatype, so each Core
//! `case` it emits is exhaustive. A view binds its expression applied to the
//! occurrence and matches the result in place of the view. A literal tests
//! equality, and a failed test drops only the row it came from. A constructor
//! no row covers is reported with the value that falls through, and an
//! alternative that no path reaches is reported as never matched.
//!
//! An alternative reached from one path is lowered in place. One reached from
//! several is bound once, as a function of its pattern variables, and each
//! path applies it.

const std = @import("std");
const core = @import("../core.zig");
const cst = @import("../lang/cst.zig");
const diagnostic = @import("../diagnostic.zig");
const string_literal = @import("../lang/string_literal.zig");
const resolve = @import("resolve.zig");
const desugar = @import("desugar.zig");
const datatypes = core.datatypes;

const Error = desugar.Error;
const Lowerer = desugar.Lowerer;
const ModuleScope = @import("scope.zig").ModuleScope;
const Entry = resolve.Scope.Entry;

fn isWildcard(name: []const u8) bool {
    return std.mem.eql(u8, name, "_");
}

/// The statements after a `do` bind, and the block's result.
pub const Rest = struct {
    statements: []const cst.Statement,
    result: cst.Expression,
    span: diagnostic.Span,
};

/// What runs when an alternative matches.
const Body = union(enum) {
    expression: cst.Expression,
    rest: Rest,
};

const Arm = struct {
    written: cst.Pattern,
    /// `written` with list, cons and boolean sugar rewritten as constructors,
    /// and node patterns as views.
    pattern: cst.Pattern,
    guard: ?cst.Expression,
    body: Body,
};

/// What a match does when no row matches.
const NoMatch = enum {
    /// Report the value that falls through.
    report,
    /// Yield `Nil`.
    nil,
};

/// Lower `case scrutinee of { alternatives }`.
pub fn caseOf(
    lowerer: *Lowerer,
    c: cst.Case,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
) Error!core.Term {
    const scrutinee = try lowerer.expression(c.scrutinee, scope);

    if (c.alternatives.len == 0) {
        try lowerer.sink.report(.type_mismatch, span, "a case has no alternatives", .{});
        return error.DesugarFailed;
    }
    for (c.alternatives) |alternative| try check(lowerer, alternative.pattern, scope);

    const arms = try lowerer.builder.slice(Arm, c.alternatives.len);
    for (c.alternatives, arms) |alternative, *arm| {
        arm.* = .{
            .written = alternative.pattern,
            .pattern = try expand(lowerer, alternative.pattern),
            .guard = alternative.guard,
            .body = .{ .expression = alternative.body },
        };
    }

    const root = switch (scrutinee.kind) {
        .symbol => |s| s,
        else => try lowerer.env.interner.fresh("scrutinee"),
    };
    return try lower(lowerer, arms, scope, span, root, scrutinee, .report);
}

/// Lower `pattern <- value; rest`. Each result of `value` the pattern does not
/// match contributes nothing.
pub fn bind(
    lowerer: *Lowerer,
    statement: cst.BindStatement,
    rest: Rest,
    scope: ?*const resolve.Scope,
) Error!core.Term {
    const b = lowerer.builder;
    try check(lowerer, statement.pattern, scope);
    const pattern = try expand(lowerer, statement.pattern);

    const value = try lowerer.expression(statement.value, scope);
    const root = try lowerer.env.interner.fresh(binderName(pattern));
    const span = statement.pattern.span;
    const arms = try b.dupeSlice(Arm, &.{.{
        .written = statement.pattern,
        .pattern = pattern,
        .guard = null,
        .body = .{ .rest = rest },
    }});
    const term = try lower(lowerer, arms, scope, span, root, b.symbol(root, span), .nil);
    return try lowerer.bind(root, value, term, statement.span);
}

fn lower(
    lowerer: *Lowerer,
    arms: []const Arm,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
    root: core.SymbolId,
    scrutinee: core.Term,
    no_match: NoMatch,
) Error!core.Term {
    const b = lowerer.builder;
    const rows = try b.slice(Row, arms.len);
    for (arms, rows, 0..) |arm, *row, i| {
        var items: std.ArrayList(Item) = .empty;
        try push(b.allocator, &items, arm.pattern, root);
        row.* = .{ .items = items.items, .bindings = &.{}, .alternative = @intCast(i) };
    }

    var matcher: Matcher = .{
        .lowerer = lowerer,
        .arms = arms,
        .span = span,
        .root = root,
        .no_match = no_match,
        .uses = try b.slice(u32, arms.len),
    };
    defer matcher.path.deinit(b.allocator);
    defer matcher.facts.deinit(b.allocator);
    @memset(matcher.uses, 0);

    const tree = try matcher.compile(rows);

    for (arms, matcher.uses) |arm, uses| {
        if (uses > 0) continue;
        try lowerer.sink.report(
            .type_mismatch,
            arm.written.span,
            "`{f}` is never matched",
            .{Written{ .pattern = arm.written }},
        );
        return error.DesugarFailed;
    }

    const shared = try b.slice(?core.SymbolId, arms.len);
    var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
    defer bindings.deinit(b.allocator);
    for (arms, matcher.uses, shared) |arm, uses, *slot| {
        slot.* = null;
        if (uses < 2) continue;
        const symbol = try lowerer.env.interner.fresh("alternative");
        slot.* = symbol;
        try bindings.append(b.allocator, .{
            .name = symbol,
            .value = try sharedAlternative(lowerer, arm, scope, span),
        });
    }

    const emitter: Emitter = .{
        .lowerer = lowerer,
        .arms = arms,
        .scope = scope,
        .span = span,
        .root = root,
        .scrutinee = scrutinee,
        .root_bound = binds(tree, root) or reads(tree, root) > 1,
        .shared = shared,
    };
    var term = try emitter.emit(tree);

    // A scrutinee that is not already a name is bound only when an
    // alternative names it or more than one test reads it.
    if (scrutinee.kind != .symbol and emitter.root_bound) {
        term = try b.let(root, scrutinee, term, span);
    }
    var i = bindings.items.len;
    while (i > 0) {
        i -= 1;
        term = try b.let(bindings.items[i].name, bindings.items[i].value, term, span);
    }
    return term;
}

/// Rewrite list, cons and boolean patterns as constructor patterns, and node
/// patterns as views. The matcher sees no other sugar.
fn expand(lowerer: *Lowerer, pattern: cst.Pattern) Error!cst.Pattern {
    const b = lowerer.builder;
    switch (pattern.kind) {
        .node, .as, .conjunction => if (try narrow(lowerer, pattern)) |narrowed| return narrowed,
        else => {},
    }
    switch (pattern.kind) {
        .node => |n| return try fieldViews(lowerer, n, pattern.span),
        .variable, .literal => return pattern,
        .boolean => |value| return builtinPattern(lowerer, if (value) .true else .false, &.{}, pattern.span),
        .constructor => |c| {
            const arguments = try b.slice(cst.Pattern, c.arguments.len);
            for (c.arguments, arguments) |argument, *out| out.* = try expand(lowerer, argument);
            return .{
                .kind = .{ .constructor = .{ .name = c.name, .arguments = arguments, .builtin = c.builtin } },
                .span = pattern.span,
            };
        },
        .cons => |c| return try cell(lowerer, try expand(lowerer, c.head), try expand(lowerer, c.tail), pattern.span),
        .list => |elements| {
            var spine = builtinPattern(lowerer, .nil, &.{}, pattern.span);
            var i = elements.len;
            while (i > 0) {
                i -= 1;
                // An inner cell spans its head element.
                const span = if (i == 0) pattern.span else elements[i].span;
                spine = try cell(lowerer, try expand(lowerer, elements[i]), spine, span);
            }
            return spine;
        },
        .as => |a| {
            const boxed = try b.allocator.create(cst.Pattern.As);
            boxed.* = .{ .name = a.name, .name_span = a.name_span, .pattern = try expand(lowerer, a.pattern) };
            return .{ .kind = .{ .as = boxed }, .span = pattern.span };
        },
        .conjunction => |c| {
            const boxed = try b.allocator.create(cst.Pattern.Conjunction);
            boxed.* = .{ .left = try expand(lowerer, c.left), .right = try expand(lowerer, c.right) };
            return .{ .kind = .{ .conjunction = boxed }, .span = pattern.span };
        },
        .view => |v| {
            const boxed = try b.allocator.create(cst.Pattern.View);
            boxed.* = .{ .function = v.function, .written = v.written, .pattern = try expand(lowerer, v.pattern) };
            return .{ .kind = .{ .view = boxed }, .span = pattern.span };
        },
    }
}

/// Append the patterns `pattern` matches against its one value, with each
/// as-pattern's name as a variable.
fn flatten(allocator: std.mem.Allocator, pattern: cst.Pattern, out: *std.ArrayList(cst.Pattern)) Error!void {
    switch (pattern.kind) {
        .as => |a| {
            try out.append(allocator, .{ .kind = .{ .variable = a.name }, .span = a.name_span });
            try flatten(allocator, a.pattern, out);
        },
        .conjunction => |c| {
            try flatten(allocator, c.left, out);
            try flatten(allocator, c.right, out);
        },
        else => try out.append(allocator, pattern),
    }
}

fn isKindedNode(pattern: cst.Pattern) bool {
    return pattern.kind == .node and pattern.kind.node.kind != null;
}

/// `p & :k { .. } & q` as `(of_kind :k -> [p & { .. } & q])`, keeping the
/// conjuncts in the order they are written. The first kinded node pattern is
/// the outer view; a later one nests inside it. Returns null when no conjunct
/// is a kinded node pattern.
fn narrow(lowerer: *Lowerer, pattern: cst.Pattern) Error!?cst.Pattern {
    const b = lowerer.builder;
    var conjuncts: std.ArrayList(cst.Pattern) = .empty;
    try flatten(b.allocator, pattern, &conjuncts);

    var outer: ?cst.Pattern = null;
    var inside: std.ArrayList(cst.Pattern) = .empty;
    for (conjuncts.items) |conjunct| {
        if (outer != null or !isKindedNode(conjunct)) {
            try inside.append(b.allocator, conjunct);
            continue;
        }
        outer = conjunct;
        const n = conjunct.kind.node;
        if (n.fields.len == 0) continue;
        const kindless = try b.allocator.create(cst.Pattern.Node);
        kindless.* = .{ .kind = null, .fields = n.fields };
        try inside.append(b.allocator, .{ .kind = .{ .node = kindless }, .span = conjunct.span });
    }
    const node = outer orelse return null;
    const n = node.kind.node;

    const element: cst.Pattern = if (inside.items.len == 0)
        .{ .kind = .{ .variable = "_" }, .span = node.span }
    else
        try conjoin(lowerer, inside.items, pattern.span);

    const apply = try b.allocator.create(cst.Apply);
    apply.* = .{
        .function = .{ .kind = .{ .primitive = "of_kind" }, .span = node.span },
        .argument = .{ .kind = .{ .kind_test = n.kind.? }, .span = n.kind_span },
    };
    return try view(
        lowerer,
        .{ .kind = .{ .apply = apply }, .span = node.span },
        try b.print("of_kind :{s}", .{n.kind.?}),
        try expand(lowerer, element),
        node.span,
    );
}

/// `{ #f = p, .. }` as `(#f -> [p]) & ..`.
///
/// Preconditions:
/// - `n` has a field.
fn fieldViews(lowerer: *Lowerer, n: *const cst.Pattern.Node, span: diagnostic.Span) Error!cst.Pattern {
    const b = lowerer.builder;
    const views = try b.slice(cst.Pattern, n.fields.len);
    for (n.fields, views) |f, *out| {
        const navigation = try b.allocator.create(cst.Navigation);
        navigation.* = .{ .node = null, .field = f.name };
        out.* = try view(
            lowerer,
            .{ .kind = .{ .navigation = navigation }, .span = f.name_span },
            try b.print("#{s}", .{f.name}),
            try expand(lowerer, f.pattern),
            f.span,
        );
    }
    return try conjoin(lowerer, views, span);
}

/// `patterns` joined left to right with `&`.
///
/// Preconditions:
/// - `patterns` is not empty.
fn conjoin(lowerer: *Lowerer, patterns: []const cst.Pattern, span: diagnostic.Span) Error!cst.Pattern {
    var result = patterns[0];
    for (patterns[1..]) |right| {
        const boxed = try lowerer.builder.allocator.create(cst.Pattern.Conjunction);
        boxed.* = .{ .left = result, .right = right };
        result = .{ .kind = .{ .conjunction = boxed }, .span = span };
    }
    return result;
}

/// `(function -> [element])`, with `element` already expanded.
fn view(
    lowerer: *Lowerer,
    function: cst.Expression,
    written: []const u8,
    element: cst.Pattern,
    span: diagnostic.Span,
) Error!cst.Pattern {
    const boxed = try lowerer.builder.allocator.create(cst.Pattern.View);
    boxed.* = .{
        .function = function,
        .written = written,
        .pattern = try cell(lowerer, element, builtinPattern(lowerer, .nil, &.{}, span), span),
    };
    return .{ .kind = .{ .view = boxed }, .span = span };
}

fn cell(lowerer: *Lowerer, head: cst.Pattern, tail: cst.Pattern, span: diagnostic.Span) Error!cst.Pattern {
    const arguments = try lowerer.builder.slice(cst.Pattern, 2);
    arguments[0] = head;
    arguments[1] = tail;
    return builtinPattern(lowerer, .cons, arguments, span);
}

fn builtinPattern(
    lowerer: *Lowerer,
    which: cst.Pattern.Builtin,
    arguments: []const cst.Pattern,
    span: diagnostic.Span,
) cst.Pattern {
    const symbol = builtinConstructor(lowerer.scope.datatypes, which).symbol;
    return .{
        .kind = .{ .constructor = .{
            .name = lowerer.env.interner.spelling(symbol),
            .arguments = arguments,
            .builtin = which,
        } },
        .span = span,
    };
}

fn builtinConstructor(registry: *const datatypes.Registry, which: cst.Pattern.Builtin) datatypes.Constructor {
    return switch (which) {
        .nil => registry.nilConstructor(),
        .cons => registry.consConstructor(),
        .false => registry.boolConstructor(false),
        .true => registry.boolConstructor(true),
    };
}

/// The literal as the expression it is compared with.
fn literalExpression(literal: cst.Pattern.Literal, span: diagnostic.Span) cst.Expression {
    return .{
        .kind = switch (literal) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .regex => |r| .{ .regex = r },
            .kind => |k| .{ .kind_test = k },
        },
        .span = span,
    };
}

/// The variable naming the whole value `pattern` matches, if one does.
fn givenName(pattern: cst.Pattern) ?[]const u8 {
    return switch (pattern.kind) {
        .variable => |name| if (isWildcard(name)) null else name,
        .as => |a| if (isWildcard(a.name)) givenName(a.pattern) else a.name,
        .conjunction => |c| givenName(c.left) orelse givenName(c.right),
        else => null,
    };
}

/// The name a bind gives the value it matches.
fn binderName(pattern: cst.Pattern) []const u8 {
    if (givenName(pattern)) |name| return name;
    if (pattern.kind == .variable) return "_";
    return "scrutinee";
}

/// Reject a pattern naming an unknown constructor or kind, giving a
/// constructor the wrong number of arguments, holding a malformed regex,
/// binding one variable twice, naming one value twice, or binding a variable
/// nested in it that shadows a local in `scope`.
fn check(lowerer: *Lowerer, pattern: cst.Pattern, scope: ?*const resolve.Scope) Error!void {
    var checker: Checker = .{ .lowerer = lowerer, .scope = scope };
    defer checker.seen.deinit(lowerer.builder.allocator);
    try checker.visit(pattern, true);
}

const Checker = struct {
    lowerer: *Lowerer,
    scope: ?*const resolve.Scope,
    seen: std.ArrayList([]const u8) = .empty,

    /// `whole` is set while `pattern` matches the whole bound value.
    fn visit(self: *Checker, pattern: cst.Pattern, whole: bool) Error!void {
        switch (pattern.kind) {
            .variable => |name| try self.variable(name, pattern.span, whole),
            .as, .conjunction => {
                var names: usize = 0;
                countNames(pattern, &names);
                if (names > 1) {
                    try self.lowerer.sink.report(
                        .duplicate_definition,
                        pattern.span,
                        "`{f}` binds one value twice",
                        .{Written{ .pattern = pattern }},
                    );
                    return error.DesugarFailed;
                }
                try self.conjuncts(pattern, whole);
            },
            .view => |v| try self.visit(v.pattern, false),
            .constructor => |c| {
                const constructor = try constructorNamed(self.lowerer, c, pattern.span);
                if (c.arguments.len != constructor.fields.len) {
                    try self.lowerer.sink.report(
                        .type_mismatch,
                        pattern.span,
                        "`{s}` binds {d} field(s), given {d}",
                        .{ c.name, constructor.fields.len, c.arguments.len },
                    );
                    return error.DesugarFailed;
                }
                for (c.arguments) |argument| try self.visit(argument, false);
            },
            .list => |elements| for (elements) |element| try self.visit(element, false),
            .cons => |c| {
                try self.visit(c.head, false);
                try self.visit(c.tail, false);
            },
            .literal => |literal| _ = try self.lowerer.expression(literalExpression(literal, pattern.span), null),
            .boolean => {},
            .node => |n| {
                if (n.kind) |kind| _ = try self.lowerer.expression(.{ .kind = .{ .kind_test = kind }, .span = n.kind_span }, null);
                for (n.fields) |f| {
                    var navigation: cst.Navigation = .{ .node = null, .field = f.name };
                    _ = try self.lowerer.expression(.{ .kind = .{ .navigation = &navigation }, .span = f.name_span }, null);
                    try self.visit(f.pattern, false);
                }
            },
        }
    }

    /// Visit the patterns an as-pattern or conjunction matches against its one value.
    fn conjuncts(self: *Checker, pattern: cst.Pattern, whole: bool) Error!void {
        switch (pattern.kind) {
            .as => |a| {
                try self.variable(a.name, a.name_span, whole);
                try self.conjuncts(a.pattern, whole);
            },
            .conjunction => |c| {
                try self.conjuncts(c.left, whole);
                try self.conjuncts(c.right, whole);
            },
            else => try self.visit(pattern, whole),
        }
    }

    fn variable(self: *Checker, name: []const u8, span: diagnostic.Span, whole: bool) Error!void {
        if (isWildcard(name)) return;
        for (self.seen.items) |earlier| {
            if (!std.mem.eql(u8, earlier, name)) continue;
            try self.lowerer.sink.report(
                .duplicate_definition,
                span,
                "`{s}` is bound twice in one pattern",
                .{name},
            );
            return error.DesugarFailed;
        }
        try self.seen.append(self.lowerer.builder.allocator, name);

        if (whole) return;
        const scope = self.scope orelse return;
        if (scope.lookup(name) == null) return;
        try self.lowerer.sink.report(
            .shadowed_local,
            span,
            "`{s}` in a pattern would shadow the local `{s}`; bind another name and compare after the bind",
            .{ name, name },
        );
        return error.DesugarFailed;
    }
};

/// Count the variables naming the value an as-pattern or conjunction matches.
fn countNames(pattern: cst.Pattern, count: *usize) void {
    switch (pattern.kind) {
        .variable => |name| {
            if (!isWildcard(name)) count.* += 1;
        },
        .as => |a| {
            if (!isWildcard(a.name)) count.* += 1;
            countNames(a.pattern, count);
        },
        .conjunction => |c| {
            countNames(c.left, count);
            countNames(c.right, count);
        },
        else => {},
    }
}

fn constructorNamed(
    lowerer: *Lowerer,
    c: cst.Pattern.Constructor,
    span: diagnostic.Span,
) Error!*const datatypes.Constructor {
    const found = if (c.builtin) |which|
        builtinConstructor(lowerer.scope.datatypes, which).symbol
    else
        try lowerer.resolveGlobal(c.name, span);
    if (found) |id| {
        if (lowerer.scope.datatypes.constructorOf(&lowerer.env.interner, id)) |constructor| return constructor;
    }
    try lowerer.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{c.name});
    return error.DesugarFailed;
}

/// The symbol a constructor pattern names.
///
/// Preconditions:
/// - `check` accepted the pattern `c` is in.
fn constructorSymbol(scope: *const ModuleScope, c: cst.Pattern.Constructor) core.SymbolId {
    if (c.builtin) |which| return builtinConstructor(scope.datatypes, which).symbol;
    return scope.value(c.name).found;
}

/// `\x_1 ... x_n -> body` over the alternative's pattern variables, in the
/// order they are written.
fn sharedAlternative(
    lowerer: *Lowerer,
    arm: Arm,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
) Error!core.Term {
    var names: std.ArrayList([]const u8) = .empty;
    try variables(lowerer.builder.allocator, arm.pattern, &names);

    const entries = try lowerer.builder.slice(Entry, names.items.len);
    for (names.items, entries) |name, *entry| {
        entry.* = .{ .name = name, .symbol = try lowerer.env.interner.fresh(name) };
    }
    const inner: resolve.Scope = .{ .parent = scope, .names = entries };

    var term = try lowerBody(lowerer, arm.body, &inner);
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        term = try lowerer.builder.lambda(entries[i].symbol, term, span);
    }
    return term;
}

fn lowerBody(lowerer: *Lowerer, body: Body, scope: *const resolve.Scope) Error!core.Term {
    return switch (body) {
        .expression => |e| try lowerer.expression(e, scope),
        .rest => |r| try lowerer.doBlock(r.statements, r.result, scope, r.span),
    };
}

fn variables(
    allocator: std.mem.Allocator,
    pattern: cst.Pattern,
    out: *std.ArrayList([]const u8),
) Error!void {
    switch (pattern.kind) {
        .variable => |name| if (!isWildcard(name)) try out.append(allocator, name),
        .constructor => |c| for (c.arguments) |argument| try variables(allocator, argument, out),
        .as => |a| {
            if (!isWildcard(a.name)) try out.append(allocator, a.name);
            try variables(allocator, a.pattern, out);
        },
        .conjunction => |c| {
            try variables(allocator, c.left, out);
            try variables(allocator, c.right, out);
        },
        .view => |v| try variables(allocator, v.pattern, out),
        .literal => {},
        .list, .cons, .boolean, .node => unreachable,
    }
}

/// Whether any leaf or view of `tree` binds a variable to `occurrence`.
fn binds(tree: *const Tree, occurrence: core.SymbolId) bool {
    switch (tree.*) {
        .leaf => |leaf| {
            if (bound(leaf.bindings, occurrence)) return true;
            const otherwise = leaf.otherwise orelse return false;
            return binds(otherwise, occurrence);
        },
        .test_ => |t| {
            for (t.branches) |branch| {
                if (binds(branch.tree, occurrence)) return true;
            }
            return false;
        },
        .view => |v| return bound(v.bindings, occurrence) or binds(v.tree, occurrence),
        .literal => |l| return binds(l.matched, occurrence) or binds(l.failed, occurrence),
        .fail => return false,
    }
}

fn bound(bindings: []const Entry, occurrence: core.SymbolId) bool {
    for (bindings) |binding| {
        if (binding.symbol == occurrence) return true;
    }
    return false;
}

/// How many tests and views in `tree` read `occurrence`.
fn reads(tree: *const Tree, occurrence: core.SymbolId) usize {
    switch (tree.*) {
        .leaf => |leaf| {
            const otherwise = leaf.otherwise orelse return 0;
            return reads(otherwise, occurrence);
        },
        .test_ => |t| {
            var count: usize = @intFromBool(t.occurrence == occurrence);
            for (t.branches) |branch| count += reads(branch.tree, occurrence);
            return count;
        },
        .view => |v| return reads(v.tree, occurrence) + @intFromBool(v.occurrence == occurrence),
        .literal => |l| return reads(l.matched, occurrence) + reads(l.failed, occurrence) +
            @intFromBool(l.occurrence == occurrence),
        .fail => return 0,
    }
}

/// A pattern still to match, and the occurrence it matches against. The
/// pattern is a variable, a constructor, a view or a literal.
const Item = struct {
    pattern: cst.Pattern,
    occurrence: core.SymbolId,
};

/// Append `pattern` against `occurrence` to `items`, with each as-pattern and
/// conjunction split into the patterns it matches against the one value.
fn push(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(Item),
    pattern: cst.Pattern,
    occurrence: core.SymbolId,
) Error!void {
    switch (pattern.kind) {
        .as => |a| {
            try items.append(allocator, .{
                .pattern = .{ .kind = .{ .variable = a.name }, .span = a.name_span },
                .occurrence = occurrence,
            });
            try push(allocator, items, a.pattern, occurrence);
        },
        .conjunction => |c| {
            try push(allocator, items, c.left, occurrence);
            try push(allocator, items, c.right, occurrence);
        },
        .variable, .constructor, .view, .literal => try items.append(allocator, .{
            .pattern = pattern,
            .occurrence = occurrence,
        }),
        .list, .cons, .boolean, .node => unreachable,
    }
}

/// The patterns an alternative still has to match, in the order they are
/// written, and what its variables are already bound to.
const Row = struct {
    items: []const Item,
    bindings: []const Entry,
    alternative: u32,
};

const Tree = union(enum) {
    leaf: Leaf,
    test_: Test,
    view: View,
    literal: Literal,
    /// No row matches.
    fail,

    const Leaf = struct {
        alternative: u32,
        bindings: []const Entry,
        /// What runs when the alternative's guard is false. Null when it has
        /// no guard.
        otherwise: ?*const Tree,
    };

    /// One branch per constructor of the occurrence's datatype, in tag order.
    const Test = struct {
        occurrence: core.SymbolId,
        branches: []const Branch,
        span: diagnostic.Span,
    };

    const Branch = struct {
        constructor: core.SymbolId,
        fields: []const core.SymbolId,
        tree: *const Tree,
    };

    /// `symbol` bound to `function` applied to `occurrence`, in scope for
    /// `tree`.
    const View = struct {
        symbol: core.SymbolId,
        function: cst.Expression,
        occurrence: core.SymbolId,
        /// The variables `function` may name, besides the enclosing scope's.
        bindings: []const Entry,
        span: diagnostic.Span,
        tree: *const Tree,
    };

    const Literal = struct {
        occurrence: core.SymbolId,
        literal: cst.Pattern.Literal,
        span: diagnostic.Span,
        matched: *const Tree,
        failed: *const Tree,
    };
};

/// A constructor test taken on the way to the current subtree.
const Step = struct {
    occurrence: core.SymbolId,
    constructor: core.SymbolId,
    fields: []const core.SymbolId,
};

/// The outcome of a literal test taken on the way to the current subtree.
const Fact = struct {
    occurrence: core.SymbolId,
    literal: cst.Pattern.Literal,
    holds: bool,
};

const Matcher = struct {
    lowerer: *Lowerer,
    arms: []const Arm,
    span: diagnostic.Span,
    root: core.SymbolId,
    no_match: NoMatch,
    /// Leaves reaching each alternative.
    uses: []u32,
    path: std.ArrayList(Step) = .empty,
    facts: std.ArrayList(Fact) = .empty,

    fn compile(self: *Matcher, rows: []const Row) Error!*const Tree {
        const b = self.lowerer.builder;
        if (rows.len == 0) {
            if (self.no_match == .nil) return try self.node(.fail);
            try self.lowerer.sink.report(
                .type_mismatch,
                self.span,
                "`{f}` is not matched",
                .{Witness{ .matcher = self, .occurrence = self.root, .nested = false }},
            );
            return error.DesugarFailed;
        }

        const first = rows[0];
        var bindings: std.ArrayList(Entry) = .empty;
        try bindings.appendSlice(b.allocator, first.bindings);
        for (first.items, 0..) |item, i| {
            switch (item.pattern.kind) {
                .variable => |name| {
                    if (!isWildcard(name)) {
                        try bindings.append(b.allocator, .{ .name = name, .symbol = item.occurrence });
                    }
                    continue;
                },
                .literal => |literal| if (self.known(item.occurrence, literal)) |holds| {
                    if (holds) continue;
                    return try self.compile(rows[1..]);
                },
                .constructor, .view => {},
                .as, .conjunction, .list, .cons, .boolean, .node => unreachable,
            }

            const narrowed = try b.dupeSlice(Row, rows);
            narrowed[0] = .{
                .items = first.items[i..],
                .bindings = bindings.items,
                .alternative = first.alternative,
            };
            return switch (item.pattern.kind) {
                .constructor => try self.split(narrowed, item),
                .view => |v| try self.bindView(narrowed, item, v),
                .literal => |literal| try self.testLiteral(narrowed, item, literal),
                else => unreachable,
            };
        }

        self.uses[first.alternative] += 1;
        const otherwise = if (self.arms[first.alternative].guard != null)
            try self.compile(rows[1..])
        else
            null;
        return try self.node(.{ .leaf = .{
            .alternative = first.alternative,
            .bindings = bindings.items,
            .otherwise = otherwise,
        } });
    }

    fn node(self: *Matcher, tree: Tree) Error!*const Tree {
        const out = try self.lowerer.builder.allocator.create(Tree);
        out.* = tree;
        return out;
    }

    /// Test the occurrence of the first row's first item, a constructor.
    fn split(self: *Matcher, rows: []const Row, item: Item) Error!*const Tree {
        const b = self.lowerer.builder;
        const occurrence = item.occurrence;
        const declared = self.lowerer.scope.datatypes.get(try self.datatypeOf(rows, occurrence));
        const branches = try b.slice(Tree.Branch, declared.constructors.len);
        for (declared.constructors, branches) |constructor, *branch| {
            const fields = try b.slice(core.SymbolId, constructor.fields.len);
            for (fields, 0..) |*field, i| {
                const name = fieldName(self.lowerer.scope, rows, occurrence, constructor.symbol, i) orelse
                    try b.print("{s}{d}", .{
                        try std.ascii.allocLowerString(b.allocator, self.lowerer.env.interner.spelling(constructor.symbol)),
                        i,
                    });
                field.* = try self.lowerer.env.interner.fresh(name);
            }

            const specialized = try self.specialize(rows, occurrence, constructor.symbol, fields);
            try self.path.append(b.allocator, .{
                .occurrence = occurrence,
                .constructor = constructor.symbol,
                .fields = fields,
            });
            const subtree = try self.compile(specialized);
            _ = self.path.pop();

            branch.* = .{ .constructor = constructor.symbol, .fields = fields, .tree = subtree };
        }
        return try self.node(.{ .test_ = .{
            .occurrence = occurrence,
            .branches = branches,
            .span = item.pattern.span,
        } });
    }

    /// The datatype every constructor matched against `occurrence` belongs to.
    fn datatypeOf(self: *Matcher, rows: []const Row, occurrence: core.SymbolId) Error!datatypes.TypeId {
        var found: ?datatypes.TypeId = null;
        for (rows) |row| {
            for (row.items) |item| {
                if (item.occurrence != occurrence) continue;
                const c = switch (item.pattern.kind) {
                    .constructor => |c| c,
                    else => continue,
                };
                const id = constructorSymbol(self.lowerer.scope, c);
                const this = datatypes.ownerOf(&self.lowerer.env.interner, id).?;
                const expected = found orelse {
                    found = this;
                    continue;
                };
                if (this != expected) {
                    try self.lowerer.sink.report(
                        .type_mismatch,
                        item.pattern.span,
                        "`{s}` is not a constructor of `{s}`",
                        .{ c.name, self.lowerer.scope.datatypes.get(expected).name },
                    );
                    return error.DesugarFailed;
                }
            }
        }
        return found.?;
    }

    /// The rows that can match when `occurrence` is built by `constructor`,
    /// with each pattern of that constructor against `occurrence` replaced by
    /// its arguments against `fields`.
    fn specialize(
        self: *Matcher,
        rows: []const Row,
        occurrence: core.SymbolId,
        constructor: core.SymbolId,
        fields: []const core.SymbolId,
    ) Error![]const Row {
        const b = self.lowerer.builder;
        var out: std.ArrayList(Row) = .empty;
        rows: for (rows) |row| {
            var items: std.ArrayList(Item) = .empty;
            for (row.items) |item| {
                if (item.occurrence != occurrence or item.pattern.kind != .constructor) {
                    try items.append(b.allocator, item);
                    continue;
                }
                const c = item.pattern.kind.constructor;
                if (constructorSymbol(self.lowerer.scope, c) != constructor) continue :rows;
                for (c.arguments, fields) |argument, field| try push(b.allocator, &items, argument, field);
            }
            try out.append(b.allocator, .{
                .items = items.items,
                .bindings = row.bindings,
                .alternative = row.alternative,
            });
        }
        return try out.toOwnedSlice(b.allocator);
    }

    /// Bind the first row's first item, a view, and match its pattern
    /// against the result.
    fn bindView(self: *Matcher, rows: []const Row, item: Item, v: *const cst.Pattern.View) Error!*const Tree {
        const b = self.lowerer.builder;
        const first = rows[0];
        const symbol = try self.lowerer.env.interner.fresh(givenName(v.pattern) orelse "view");
        var items: std.ArrayList(Item) = .empty;
        try push(b.allocator, &items, v.pattern, symbol);
        try items.appendSlice(b.allocator, first.items[1..]);

        const replaced = try b.dupeSlice(Row, rows);
        replaced[0] = .{ .items = items.items, .bindings = first.bindings, .alternative = first.alternative };
        return try self.node(.{ .view = .{
            .symbol = symbol,
            .function = v.function,
            .occurrence = item.occurrence,
            .bindings = first.bindings,
            .span = item.pattern.span,
            .tree = try self.compile(replaced),
        } });
    }

    /// Test the first row's first item, a literal. A failed test drops only
    /// that row.
    fn testLiteral(self: *Matcher, rows: []const Row, item: Item, literal: cst.Pattern.Literal) Error!*const Tree {
        const b = self.lowerer.builder;
        const first = rows[0];

        try self.facts.append(b.allocator, .{ .occurrence = item.occurrence, .literal = literal, .holds = false });
        const failed = try self.compile(rows[1..]);
        _ = self.facts.pop();

        const matching = try b.dupeSlice(Row, rows);
        matching[0] = .{ .items = first.items[1..], .bindings = first.bindings, .alternative = first.alternative };
        try self.facts.append(b.allocator, .{ .occurrence = item.occurrence, .literal = literal, .holds = true });
        const matched = try self.compile(matching);
        _ = self.facts.pop();

        return try self.node(.{ .literal = .{
            .occurrence = item.occurrence,
            .literal = literal,
            .span = item.pattern.span,
            .matched = matched,
            .failed = failed,
        } });
    }

    /// Whether the literal tests on the current path decide whether
    /// `occurrence` matches `literal`.
    fn known(self: *const Matcher, occurrence: core.SymbolId, literal: cst.Pattern.Literal) ?bool {
        for (self.facts.items) |fact| {
            if (fact.occurrence != occurrence) continue;
            if (sameLiteral(fact.literal, literal)) return fact.holds;
            if (fact.holds and excludes(fact.literal, literal)) return false;
        }
        return null;
    }

    /// The step that built `occurrence` on the current path, if one did.
    fn stepFor(self: *const Matcher, occurrence: core.SymbolId) ?Step {
        for (self.path.items) |step| {
            if (step.occurrence == occurrence) return step;
        }
        return null;
    }
};

fn sameLiteral(a: cst.Pattern.Literal, b: cst.Pattern.Literal) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .number => |n| n == b.number,
        .string => |s| std.mem.eql(u8, s, b.string),
        .regex => |r| std.mem.eql(u8, r, b.regex),
        .kind => |k| std.mem.eql(u8, k, b.kind),
    };
}

/// Whether a value equal to `held` cannot equal `other`. A regex decides
/// nothing about another literal.
fn excludes(held: cst.Pattern.Literal, other: cst.Pattern.Literal) bool {
    if (held == .regex or other == .regex) return false;
    return std.meta.activeTag(held) == std.meta.activeTag(other) and !sameLiteral(held, other);
}

/// The first variable written for a field. Returns null for a field some row
/// tests but none names, and `_` for a field nothing uses.
fn fieldName(
    scope: *const ModuleScope,
    rows: []const Row,
    occurrence: core.SymbolId,
    constructor: core.SymbolId,
    index: usize,
) ?[]const u8 {
    var tested = false;
    for (rows) |row| {
        for (row.items) |item| {
            if (item.occurrence != occurrence) continue;
            const c = switch (item.pattern.kind) {
                .constructor => |c| c,
                else => continue,
            };
            if (constructorSymbol(scope, c) != constructor) continue;
            const argument = c.arguments[index];
            if (givenName(argument)) |name| return name;
            if (argument.kind != .variable) tested = true;
        }
    }
    return if (tested) null else "_";
}

const Emitter = struct {
    lowerer: *Lowerer,
    arms: []const Arm,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
    root: core.SymbolId,
    scrutinee: core.Term,
    /// Whether the scrutinee is read through `root`.
    root_bound: bool,
    shared: []const ?core.SymbolId,

    fn emit(self: Emitter, tree: *const Tree) Error!core.Term {
        const b = self.lowerer.builder;
        switch (tree.*) {
            .leaf => |leaf| {
                const inner: resolve.Scope = .{ .parent = self.scope, .names = leaf.bindings };
                const otherwise = leaf.otherwise orelse return try self.body(leaf, &inner);
                const guard = self.arms[leaf.alternative].guard.?;
                const condition = try self.lowerer.expression(guard, &inner);
                const matched = try self.body(leaf, &inner);
                return try self.choose(condition, try self.emit(otherwise), matched, guard.span);
            },
            .test_ => |t| {
                const alternatives = try b.slice(core.Case.Alternative, t.branches.len);
                for (t.branches, alternatives) |branch, *out| {
                    out.* = .{
                        .constructor = branch.constructor,
                        .binders = branch.fields,
                        .body = try self.emit(branch.tree),
                    };
                }
                return try b.case(self.occurrence(t.occurrence, t.span), alternatives, self.span);
            },
            .view => |v| {
                const inner: resolve.Scope = .{ .parent = self.scope, .names = v.bindings };
                const value = try b.apply(
                    try self.lowerer.expression(v.function, &inner),
                    self.occurrence(v.occurrence, v.span),
                    v.span,
                );
                return try b.let(v.symbol, value, try self.emit(v.tree), v.span);
            },
            .literal => |l| {
                const operator: cst.BinaryOperator = if (l.literal == .regex) .match else .eq;
                const condition = try self.lowerer.binaryTerms(
                    operator,
                    self.occurrence(l.occurrence, l.span),
                    try self.lowerer.expression(literalExpression(l.literal, l.span), null),
                    l.span,
                );
                const matched = try self.emit(l.matched);
                return try self.choose(condition, try self.emit(l.failed), matched, l.span);
            },
            .fail => return b.symbol(self.lowerer.scope.datatypes.nilConstructor().symbol, self.span),
        }
    }

    fn occurrence(self: Emitter, symbol: core.SymbolId, span: diagnostic.Span) core.Term {
        if (symbol == self.root and !self.root_bound) return self.scrutinee;
        return self.lowerer.builder.symbol(symbol, span);
    }

    /// `case condition of { False -> otherwise; True -> matched }`.
    fn choose(
        self: Emitter,
        condition: core.Term,
        otherwise: core.Term,
        matched: core.Term,
        span: diagnostic.Span,
    ) Error!core.Term {
        const registry = self.lowerer.scope.datatypes;
        const alternatives = try self.lowerer.builder.dupeSlice(core.Case.Alternative, &.{
            .{ .constructor = registry.boolConstructor(false).symbol, .binders = &.{}, .body = otherwise },
            .{ .constructor = registry.boolConstructor(true).symbol, .binders = &.{}, .body = matched },
        });
        return try self.lowerer.builder.case(condition, alternatives, span);
    }

    fn body(self: Emitter, leaf: Tree.Leaf, inner: *const resolve.Scope) Error!core.Term {
        const b = self.lowerer.builder;
        const arm = self.arms[leaf.alternative];
        const function = self.shared[leaf.alternative] orelse return try lowerBody(self.lowerer, arm.body, inner);
        var names: std.ArrayList([]const u8) = .empty;
        try variables(b.allocator, arm.pattern, &names);
        const arguments = try b.slice(core.Term, names.items.len);
        for (names.items, arguments) |name, *argument| {
            argument.* = b.symbol(lookup(leaf.bindings, name), self.span);
        }
        return try b.applyMany(b.symbol(function, self.span), arguments, self.span);
    }

    fn lookup(bindings: []const Entry, name: []const u8) core.SymbolId {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding.symbol;
        }
        unreachable;
    }
};

/// Formats as the value that reaches `occurrence` on the current path, with
/// `_` for any part no test has fixed.
const Witness = struct {
    matcher: *const Matcher,
    occurrence: core.SymbolId,
    nested: bool,

    pub fn format(self: Witness, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const step = self.matcher.stepFor(self.occurrence) orelse return w.writeAll("_");
        if (self.isList(step)) return self.formatList(w, step);
        const name = self.matcher.lowerer.env.interner.spelling(step.constructor);
        const parenthesize = self.nested and step.fields.len > 0;
        if (parenthesize) try w.writeByte('(');
        try w.writeAll(name);
        for (step.fields) |field| {
            try w.writeByte(' ');
            try self.at(field, true).format(w);
        }
        if (parenthesize) try w.writeByte(')');
    }

    fn at(self: Witness, occurrence: core.SymbolId, nested: bool) Witness {
        return .{ .matcher = self.matcher, .occurrence = occurrence, .nested = nested };
    }

    fn isList(self: Witness, step: Step) bool {
        const lowerer = self.matcher.lowerer;
        return datatypes.ownerOf(&lowerer.env.interner, step.constructor) == lowerer.scope.datatypes.listId();
    }

    /// The step fixing the tail of the chain starting at `step`: a `Nil`, or
    /// null for a tail no test has fixed.
    fn end(self: Witness, step: Step) ?Step {
        var cursor = step;
        while (cursor.fields.len == 2) {
            cursor = self.matcher.stepFor(cursor.fields[1]) orelse return null;
        }
        return cursor;
    }

    /// `[a, b]` when the chain ends in `Nil`, `a : b : _` when its tail is open.
    fn formatList(self: Witness, w: *std.Io.Writer, first: Step) std.Io.Writer.Error!void {
        const closed = self.end(first) != null;
        const parenthesize = self.nested and !closed;
        try w.writeAll(if (closed) "[" else if (parenthesize) "(" else "");
        var cursor: ?Step = first;
        var i: usize = 0;
        while (cursor) |step| : (i += 1) {
            if (step.fields.len == 0) break;
            if (i > 0) try w.writeAll(if (closed) ", " else " : ");
            const head = self.matcher.stepFor(step.fields[0]);
            const open_head = if (head) |h| self.isList(h) and self.end(h) == null else false;
            try self.at(step.fields[0], open_head).format(w);
            cursor = self.matcher.stepFor(step.fields[1]);
            if (cursor == null) try w.writeAll(" : _");
        }
        try w.writeAll(if (closed) "]" else if (parenthesize) ")" else "");
    }
};

/// Formats a pattern as it would be written.
const Written = struct {
    pattern: cst.Pattern,
    /// The loosest form written here without parentheses.
    context: Precedence = .conjunction,

    const Precedence = enum(u2) { conjunction, cons, application, atom };

    pub fn format(self: Written, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const parenthesize = @intFromEnum(precedence(self.pattern)) < @intFromEnum(self.context);
        if (parenthesize) try w.writeByte('(');
        switch (self.pattern.kind) {
            .variable => |name| try w.writeAll(name),
            .constructor => |c| {
                try w.writeAll(c.name);
                for (c.arguments) |argument| {
                    try w.writeByte(' ');
                    try (Written{ .pattern = argument, .context = .atom }).format(w);
                }
            },
            .list => |elements| {
                try w.writeByte('[');
                for (elements, 0..) |element, i| {
                    if (i > 0) try w.writeAll(", ");
                    try (Written{ .pattern = element }).format(w);
                }
                try w.writeByte(']');
            },
            .cons => |c| {
                try (Written{ .pattern = c.head, .context = .application }).format(w);
                try w.writeAll(" : ");
                try (Written{ .pattern = c.tail, .context = .cons }).format(w);
            },
            .as => |a| {
                try w.print("{s}@", .{a.name});
                try (Written{ .pattern = a.pattern, .context = .atom }).format(w);
            },
            .conjunction => |c| {
                try (Written{ .pattern = c.left }).format(w);
                try w.writeAll(" & ");
                try (Written{ .pattern = c.right, .context = .cons }).format(w);
            },
            .view => |v| {
                try w.print("({s} -> ", .{v.written});
                try (Written{ .pattern = v.pattern }).format(w);
                try w.writeByte(')');
            },
            .literal => |l| switch (l) {
                .number => |n| try w.print("{d}", .{n}),
                .string => |s| try w.print("\"{f}\"", .{string_literal.fmt(s)}),
                .regex => |r| try w.print("r\"{s}\"", .{r}),
                .kind => |k| try w.print(":{s}", .{k}),
            },
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .node => |n| {
                if (n.kind) |k| try w.print(":{s} ", .{k});
                if (n.fields.len == 0) return w.writeAll("{}");
                try w.writeAll("{ ");
                for (n.fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("#{s} = ", .{f.name});
                    try (Written{ .pattern = f.pattern }).format(w);
                }
                try w.writeAll(" }");
            },
        }
        if (parenthesize) try w.writeByte(')');
    }

    fn precedence(pattern: cst.Pattern) Precedence {
        return switch (pattern.kind) {
            .conjunction => .conjunction,
            .cons => .cons,
            .constructor => |c| if (c.arguments.len > 0) .application else .atom,
            .variable, .list, .as, .view, .literal, .boolean, .node => .atom,
        };
    }
};
