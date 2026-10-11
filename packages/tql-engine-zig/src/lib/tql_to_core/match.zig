//! Patterns to flat Core `case`, for `case` alternatives and `do` binds.
//!
//! Compiles to a decision tree. A row is the patterns its alternative still
//! has to match, each against an occurrence, in the order they are written,
//! and the first remaining row decides the next step. A constructor test
//! splits over every constructor of the occurrence's datatype, so each Core
//! `case` it emits is exhaustive. A view binds its expression applied to the
//! occurrence and matches the result in place of the view. A literal tests
//! equality, and a failed test drops only the row it came from. A pattern
//! synonym calls its matcher, matches its arguments against the values the
//! matcher hands back, and like a literal drops only its own row on failure. A
//! constructor no row covers is reported with the value that falls through,
//! and an alternative that no path reaches is reported as never matched.
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
const Entry = resolve.Scope.Entry;

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
    holes: Holes,
};

/// A matcher's success: `continuation` applied to the pattern variables
/// `names`, in order.
const Holes = struct {
    continuation: core.SymbolId,
    names: []const []const u8,
    span: diagnostic.Span,
};

const Arm = struct {
    written: cst.Pattern,
    pattern: Pattern,
    guard: ?cst.Expression,
    body: Body,
};

/// A pattern as the matcher sees it: names resolved, and sugar rewritten as
/// constructors and views.
const Pattern = struct {
    kind: Kind,
    span: diagnostic.Span,

    const Kind = union(enum) {
        variable: []const u8,
        wildcard,
        constructor: Constructor,
        synonym: Synonym,
        view: *const View,
        literal: cst.Pattern.Literal,
        /// Each of these against the one value.
        all: []const Pattern,
    };

    const Constructor = struct {
        symbol: core.SymbolId,
        arguments: []const Pattern,
    };

    const Synonym = struct {
        symbol: core.SymbolId,
        matcher: core.SymbolId,
        arguments: []const Pattern,
    };

    const View = struct {
        function: Function,
        pattern: Pattern,
        /// Set when `function` yields `[]` or `[x]` for the value `x` it views.
        yields_self: bool = false,
    };
};

/// A view's function: as written, lowered in the scope of the variables bound
/// before the view, or already lowered.
const Function = union(enum) {
    written: cst.Expression,
    lowered: core.Term,
};

/// What a match does when no row matches.
const NoMatch = union(enum) {
    /// Report the value that falls through. A scrutinee written as a list
    /// literal adds that its length is not checked.
    report: struct { list_literal: bool },
    /// Yield this term.
    fallthrough: core.Term,
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
        try lowerer.sink.report(.non_exhaustive, span, "a case has no alternatives", .{});
        return error.DesugarFailed;
    }

    const arms = try lowerer.builder.slice(Arm, c.alternatives.len);
    for (c.alternatives, arms) |alternative, *arm| {
        arm.* = .{
            .written = alternative.pattern,
            .pattern = try kernel(lowerer, alternative.pattern),
            .guard = alternative.guard,
            .body = .{ .expression = alternative.body },
        };
    }

    const root = switch (scrutinee.kind) {
        .symbol => |s| s,
        else => try lowerer.env.interner.fresh("scrutinee"),
    };
    return try lower(lowerer, arms, scope, span, root, scrutinee, .{ .report = .{
        .list_literal = c.scrutinee.kind == .list,
    } });
}

/// Lower `pattern <- value; rest`. A result of `value` the pattern does not
/// match yields `empty`.
pub fn bind(
    lowerer: *Lowerer,
    statement: cst.BindStatement,
    rest: Rest,
    scope: ?*const resolve.Scope,
) Error!core.Term {
    const b = lowerer.builder;
    const pattern = try kernel(lowerer, statement.pattern);

    const value = try lowerer.expression(statement.value, scope);
    const root = try lowerer.env.interner.fresh(binderName(pattern));
    const span = statement.pattern.span;
    const arms = try b.dupeSlice(Arm, &.{.{
        .written = statement.pattern,
        .pattern = pattern,
        .guard = null,
        .body = .{ .rest = rest },
    }});
    const term = try lower(lowerer, arms, scope, span, root, b.symbol(root, span), .{ .fallthrough = try lowerer.known(.empty, span) });
    return try lowerer.bind(root, value, term, statement.span);
}

/// The matcher `synonym` declares: `\s k f -> case s of { body -> k x_1 .. x_n }`,
/// yielding `f` when `body` does not match.
pub fn matcherOf(lowerer: *Lowerer, synonym: *const cst.PatternSynonym) Error!core.Term {
    const b = lowerer.builder;
    const names = try checkParameters(lowerer, synonym);

    const span = synonym.span;
    const s = try lowerer.env.interner.fresh("s");
    const k = try lowerer.env.interner.fresh("k");
    const f = try lowerer.env.interner.fresh("f");

    const arms = try b.dupeSlice(Arm, &.{.{
        .written = synonym.body,
        .pattern = try kernel(lowerer, synonym.body),
        .guard = null,
        .body = .{ .holes = .{ .continuation = k, .names = names, .span = synonym.body.span } },
    }});
    const term = try lower(lowerer, arms, null, synonym.body.span, s, b.symbol(s, span), .{ .fallthrough = b.symbol(f, span) });
    return try b.lambda(s, try b.lambda(k, try b.lambda(f, term, span), span), span);
}

/// Returns the parameters' names. Rejects a synonym whose parameters repeat,
/// whose body binds a variable that is not a parameter, or whose body leaves a
/// parameter unbound.
fn checkParameters(lowerer: *Lowerer, synonym: *const cst.PatternSynonym) Error![]const []const u8 {
    const names = try lowerer.builder.slice([]const u8, synonym.parameters.len);
    for (synonym.parameters, names, 0..) |parameter, *name, i| {
        name.* = parameter.name orelse {
            try lowerer.sink.report(
                .unresolved_name,
                parameter.span,
                "the parameter `_` of `{s}` is not bound by its pattern",
                .{synonym.name},
            );
            return error.DesugarFailed;
        };
        for (names[0..i]) |earlier| {
            if (!std.mem.eql(u8, earlier, name.*)) continue;
            try lowerer.sink.report(
                .duplicate_definition,
                parameter.span,
                "`{s}` names two parameters of `{s}`",
                .{ name.*, synonym.name },
            );
            return error.DesugarFailed;
        }
    }

    var binders: std.ArrayList(Variable) = .empty;
    try boundVariables(lowerer.builder.allocator, synonym.body, &binders);
    for (binders.items) |variable| {
        for (names) |name| {
            if (std.mem.eql(u8, name, variable.name)) break;
        } else {
            try lowerer.sink.report(
                .unresolved_name,
                variable.span,
                "`{s}` is not a parameter of `{s}`, and a synonym binds only its parameters",
                .{ variable.name, synonym.name },
            );
            return error.DesugarFailed;
        }
    }
    for (synonym.parameters, names) |parameter, name| {
        for (binders.items) |variable| {
            if (std.mem.eql(u8, name, variable.name)) break;
        } else {
            try lowerer.sink.report(
                .unresolved_name,
                parameter.span,
                "the parameter `{s}` of `{s}` is not bound by its pattern",
                .{ name, synonym.name },
            );
            return error.DesugarFailed;
        }
    }
    return names;
}

const Variable = struct { name: []const u8, span: diagnostic.Span };

/// Append every variable `pattern` binds, as written.
fn boundVariables(allocator: std.mem.Allocator, pattern: cst.Pattern, out: *std.ArrayList(Variable)) Error!void {
    switch (pattern.kind) {
        .variable => |name| try out.append(allocator, .{ .name = name, .span = pattern.span }),
        .wildcard => {},
        .as => |a| {
            try out.append(allocator, .{ .name = a.name, .span = a.name_span });
            try boundVariables(allocator, a.pattern, out);
        },
        .conjunction => |c| {
            try boundVariables(allocator, c.left, out);
            try boundVariables(allocator, c.right, out);
        },
        .cons => |c| {
            try boundVariables(allocator, c.head, out);
            try boundVariables(allocator, c.tail, out);
        },
        .constructor => |c| for (c.arguments) |argument| try boundVariables(allocator, argument, out),
        .list, .tuple => |elements| for (elements) |element| try boundVariables(allocator, element, out),
        .view => |v| try boundVariables(allocator, v.pattern, out),
        .node => |n| for (n.fields) |f| try boundVariables(allocator, f.pattern, out),
        .literal => {},
    }
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
        .under_synonym = try b.slice(bool, arms.len),
    };
    defer matcher.path.deinit(b.allocator);
    defer matcher.facts.deinit(b.allocator);
    defer matcher.calls.deinit(b.allocator);
    @memset(matcher.uses, 0);
    @memset(matcher.under_synonym, false);

    const tree = try matcher.compile(rows);

    for (arms, matcher.uses) |arm, uses| {
        if (uses > 0) continue;
        try lowerer.sink.report(
            .redundant_alternative,
            arm.written.span,
            "`{f}` is never matched",
            .{Written{ .pattern = arm.written }},
        );
        return error.DesugarFailed;
    }

    const shared = try b.slice(?Shared, arms.len);
    var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
    defer bindings.deinit(b.allocator);
    for (arms, matcher.uses, shared, 0..) |arm, uses, *slot, i| {
        slot.* = null;
        if (uses < 2) continue;
        var variables: std.ArrayList(Variable) = .empty;
        try boundVariables(b.allocator, arm.written, &variables);
        const symbol = try lowerer.env.interner.fresh("alternative");
        if (!matcher.under_synonym[i]) {
            lowerer.env.interner.setDetails(symbol, .{ .join = .{ .arity = @intCast(variables.items.len) } });
        }
        slot.* = .{ .symbol = symbol, .variables = variables.items };
        try bindings.append(b.allocator, .{
            .name = symbol,
            .value = try sharedAlternative(lowerer, arm, variables.items, scope, span),
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
        .no_match = no_match,
    };
    var term = try emitter.emit(tree);

    // A scrutinee that is not already a name is bound only when an
    // alternative names it or more than one test reads it.
    if (scrutinee.kind != .symbol and emitter.root_bound) {
        term = try b.let(root, scrutinee, term, span);
    }
    return try b.lets(bindings.items, term, span);
}

/// `pattern` expanded. Rejects one binding a variable twice.
fn kernel(lowerer: *Lowerer, pattern: cst.Pattern) Error!Pattern {
    const expanded = try expand(lowerer, pattern);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(lowerer.builder.allocator);
    try linear(lowerer, expanded, &seen);
    return expanded;
}

fn linear(lowerer: *Lowerer, pattern: Pattern, seen: *std.ArrayList([]const u8)) Error!void {
    switch (pattern.kind) {
        .variable => |name| {
            for (seen.items) |earlier| {
                if (!std.mem.eql(u8, earlier, name)) continue;
                try lowerer.sink.report(.duplicate_definition, pattern.span, "`{s}` is bound twice in one pattern", .{name});
                return error.DesugarFailed;
            }
            try seen.append(lowerer.builder.allocator, name);
        },
        .wildcard, .literal => {},
        .constructor => |c| for (c.arguments) |argument| try linear(lowerer, argument, seen),
        .synonym => |s| for (s.arguments) |argument| try linear(lowerer, argument, seen),
        .view => |v| try linear(lowerer, v.pattern, seen),
        .all => |patterns| for (patterns) |p| try linear(lowerer, p, seen),
    }
}

/// Resolve the names `pattern` uses, and rewrite list and cons patterns as
/// constructor patterns, node patterns as views, and as-patterns and
/// conjunctions as `all`. Rejects a pattern naming an unknown
/// constructor or kind, giving a constructor the wrong number of arguments,
/// or holding a malformed regex.
fn expand(lowerer: *Lowerer, pattern: cst.Pattern) Error!Pattern {
    const b = lowerer.builder;
    const span = pattern.span;
    switch (pattern.kind) {
        .variable => |name| return .{ .kind = .{ .variable = name }, .span = span },
        .wildcard => return .{ .kind = .wildcard, .span = span },
        .literal => |literal| {
            _ = try lowerer.expression(literalExpression(literal, span), null);
            return .{ .kind = .{ .literal = literal }, .span = span };
        },
        .constructor => |c| {
            const kind: Pattern.Kind = if (try synonymNamed(lowerer, c, span)) |symbol| blk: {
                const matcher = lowerer.env.interner.details(symbol).synonym.matcher;
                const arity = lowerer.env.interner.details(matcher).matcher.arity;
                if (c.arguments.len != arity) {
                    try lowerer.sink.report(
                        .type_mismatch,
                        span,
                        "`{s}` takes {d} argument(s), given {d}",
                        .{ c.name, arity, c.arguments.len },
                    );
                    return error.DesugarFailed;
                }
                break :blk .{ .synonym = .{ .symbol = symbol, .matcher = matcher, .arguments = try expandAll(lowerer, c.arguments) } };
            } else blk: {
                const constructor = try constructorNamed(lowerer, c, span);
                if (c.arguments.len != constructor.fields.len) {
                    try lowerer.sink.report(
                        .type_mismatch,
                        span,
                        "`{s}` binds {d} field(s), given {d}",
                        .{ c.name, constructor.fields.len, c.arguments.len },
                    );
                    return error.DesugarFailed;
                }
                break :blk .{ .constructor = .{ .symbol = constructor.symbol, .arguments = try expandAll(lowerer, c.arguments) } };
            };
            return .{ .kind = kind, .span = span };
        },
        .cons => |c| return try cell(lowerer, try expand(lowerer, c.head), try expand(lowerer, c.tail), span),
        .tuple => |components| {
            return constructorPattern(try lowerer.tupleConstructor(@intCast(components.len)), try expandAll(lowerer, components), span);
        },
        .list => |elements| {
            var spine = nilPattern(lowerer, span);
            var i = elements.len;
            while (i > 0) {
                i -= 1;
                // An inner cell spans its head element.
                const cell_span = if (i == 0) span else elements[i].span;
                spine = try cell(lowerer, try expand(lowerer, elements[i]), spine, cell_span);
            }
            return spine;
        },
        .view => |v| {
            const boxed = try b.allocator.create(Pattern.View);
            boxed.* = .{
                .function = .{ .written = v.function },
                .pattern = try expand(lowerer, v.pattern),
            };
            return .{ .kind = .{ .view = boxed }, .span = span };
        },
        .node, .as, .conjunction => {
            var conjuncts: std.ArrayList(cst.Pattern) = .empty;
            try flatten(b.allocator, pattern, &conjuncts);
            return try conjoin(lowerer, conjuncts.items, span);
        },
    }
}

fn expandAll(lowerer: *Lowerer, patterns: []const cst.Pattern) Error![]const Pattern {
    const out = try lowerer.builder.slice(Pattern, patterns.len);
    for (patterns, out) |pattern, *slot| slot.* = try expand(lowerer, pattern);
    return out;
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

/// `conjuncts` against one value, keeping the order they are written. A node
/// pattern's fields become `(field[f] -> [p])` views. The first kinded node
/// pattern `:k { .. }` becomes the outer view `(run (of_kind :k) -> [..])`
/// holding every conjunct; a later one nests inside it.
fn conjoin(lowerer: *Lowerer, conjuncts: []const cst.Pattern, span: diagnostic.Span) Error!Pattern {
    const b = lowerer.builder;
    var outer: ?cst.Pattern = null;
    var inside: std.ArrayList(Pattern) = .empty;
    for (conjuncts) |conjunct| {
        const n = switch (conjunct.kind) {
            .node => |n| n,
            else => {
                try inside.append(b.allocator, try expand(lowerer, conjunct));
                continue;
            },
        };
        if (n.kind != null) {
            if (outer != null) {
                try inside.append(b.allocator, try conjoin(lowerer, &.{conjunct}, conjunct.span));
                continue;
            }
            outer = conjunct;
        }
        for (n.fields) |f| {
            const function = try lowerer.fieldFunction(f.name, f.name_span);
            try inside.append(b.allocator, try view(lowerer, function, try expand(lowerer, f.pattern), false, f.span));
        }
    }

    const node = outer orelse return try all(lowerer, inside.items, span);
    const n = node.kind.node;
    const element: Pattern = if (inside.items.len == 0)
        .{ .kind = .wildcard, .span = node.span }
    else
        try all(lowerer, inside.items, span);
    const kind = try lowerer.expression(.{ .kind = .{ .kind_test = n.kind.? }, .span = n.kind_span }, null);
    const of_kind = try b.apply(try lowerer.known(.of_kind, node.span), kind, node.span);
    const function = try b.apply(try lowerer.known(.run, node.span), of_kind, node.span);
    return try view(lowerer, function, element, true, node.span);
}

/// Each of `patterns` against one value.
fn all(lowerer: *Lowerer, patterns: []const Pattern, span: diagnostic.Span) Error!Pattern {
    if (patterns.len == 1) return patterns[0];
    return .{ .kind = .{ .all = try lowerer.builder.dupeSlice(Pattern, patterns) }, .span = span };
}

/// `(function -> [element])`.
fn view(lowerer: *Lowerer, function: core.Term, element: Pattern, yields_self: bool, span: diagnostic.Span) Error!Pattern {
    const boxed = try lowerer.builder.allocator.create(Pattern.View);
    boxed.* = .{
        .function = .{ .lowered = function },
        .pattern = try cell(lowerer, element, nilPattern(lowerer, span), span),
        .yields_self = yields_self,
    };
    return .{ .kind = .{ .view = boxed }, .span = span };
}

fn cell(lowerer: *Lowerer, head: Pattern, tail: Pattern, span: diagnostic.Span) Error!Pattern {
    const arguments = try lowerer.builder.slice(Pattern, 2);
    arguments[0] = head;
    arguments[1] = tail;
    return constructorPattern(lowerer.scope.env.datatypes.consConstructor().symbol, arguments, span);
}

fn nilPattern(lowerer: *Lowerer, span: diagnostic.Span) Pattern {
    return constructorPattern(lowerer.scope.env.datatypes.nilConstructor().symbol, &.{}, span);
}

fn constructorPattern(symbol: core.SymbolId, arguments: []const Pattern, span: diagnostic.Span) Pattern {
    return .{ .kind = .{ .constructor = .{ .symbol = symbol, .arguments = arguments } }, .span = span };
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
fn givenName(pattern: Pattern) ?[]const u8 {
    switch (pattern.kind) {
        .variable => |name| return name,
        .view => |v| return if (v.yields_self) givenName(v.pattern.kind.constructor.arguments[0]) else null,
        .all => |patterns| {
            for (patterns) |p| {
                if (givenName(p)) |name| return name;
            }
            return null;
        },
        else => return null,
    }
}

/// The name a bind gives the value it matches.
fn binderName(pattern: Pattern) []const u8 {
    if (givenName(pattern)) |name| return name;
    return switch (pattern.kind) {
        .wildcard => "_",
        .view => |v| if (v.yields_self) binderName(v.pattern.kind.constructor.arguments[0]) else "scrutinee",
        else => "scrutinee",
    };
}

fn constructorNamed(
    lowerer: *Lowerer,
    c: cst.Pattern.Constructor,
    span: diagnostic.Span,
) Error!*const datatypes.Constructor {
    if (try lowerer.resolveGlobal(c.name, span)) |id| {
        if (lowerer.scope.env.datatypes.constructorOf(&lowerer.env.interner, id)) |constructor| return constructor;
    }
    try lowerer.sink.report(.unresolved_name, span, "`{s}` is not a constructor or a pattern synonym", .{c.name});
    return error.DesugarFailed;
}

/// The pattern synonym `c` names, or null when it names none.
fn synonymNamed(lowerer: *Lowerer, c: cst.Pattern.Constructor, span: diagnostic.Span) Error!?core.SymbolId {
    const id = try lowerer.resolveGlobal(c.name, span) orelse return null;
    return if (lowerer.env.interner.details(id) == .synonym) id else null;
}

/// An alternative bound once as a function of its pattern variables.
const Shared = struct {
    symbol: core.SymbolId,
    /// The parameters, in the order they are written.
    variables: []const Variable,
};

/// `\x_1 ... x_n -> body` over `variables`, the alternative's pattern
/// variables.
fn sharedAlternative(
    lowerer: *Lowerer,
    arm: Arm,
    variables: []const Variable,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
) Error!core.Term {
    const entries = try lowerer.builder.slice(Entry, variables.len);
    for (variables, entries) |variable, *entry| {
        entry.* = .{ .name = variable.name, .symbol = try lowerer.env.interner.fresh(variable.name) };
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
        .holes => |h| {
            const arguments = try lowerer.builder.slice(core.Term, h.names.len);
            for (h.names, arguments) |name, *argument| argument.* = lowerer.builder.symbol(scope.lookup(name).?, h.span);
            return try lowerer.builder.applyMany(lowerer.builder.symbol(h.continuation, h.span), arguments, h.span);
        },
    };
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
        .synonym => |s| return binds(s.matched, occurrence) or binds(s.failed, occurrence),
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
        .synonym => |s| return reads(s.matched, occurrence) + reads(s.failed, occurrence) +
            @intFromBool(s.occurrence == occurrence),
        .fail => return 0,
    }
}

/// A pattern still to match, and the occurrence it matches against. The
/// pattern is never `all`.
const Item = struct {
    pattern: Pattern,
    occurrence: core.SymbolId,
};

/// Append `pattern` against `occurrence` to `items`, with each `all` split
/// into the patterns it matches against the one value.
fn push(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(Item),
    pattern: Pattern,
    occurrence: core.SymbolId,
) Error!void {
    switch (pattern.kind) {
        .all => |patterns| for (patterns) |p| try push(allocator, items, p, occurrence),
        else => try items.append(allocator, .{ .pattern = pattern, .occurrence = occurrence }),
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
    synonym: Synonym,
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
        function: Function,
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

    /// `matcher` applied to `occurrence`, to `matched` under a lambda for
    /// each of `holes`, and to `failed`.
    const Synonym = struct {
        occurrence: core.SymbolId,
        matcher: core.SymbolId,
        holes: []const core.SymbolId,
        /// The span of the argument pattern matched against each hole.
        hole_spans: []const diagnostic.Span,
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

/// The outcome of a synonym test taken on the way to the current subtree, and
/// where it put the values it matched.
const Call = struct {
    occurrence: core.SymbolId,
    matcher: core.SymbolId,
    holes: []const core.SymbolId,
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
    /// Whether a leaf reaching each alternative is under a synonym test.
    under_synonym: []bool,
    path: std.ArrayList(Step) = .empty,
    facts: std.ArrayList(Fact) = .empty,
    calls: std.ArrayList(Call) = .empty,

    fn compile(self: *Matcher, rows: []const Row) Error!*const Tree {
        const b = self.lowerer.builder;
        if (rows.len == 0) {
            const report = switch (self.no_match) {
                .report => |r| r,
                .fallthrough => return try self.node(.fail),
            };
            const note = if (report.list_literal) "; a list literal's length is not checked" else "";
            try self.lowerer.sink.report(
                .non_exhaustive,
                self.span,
                "`{f}` is not matched{s}",
                .{ Witness{ .matcher = self, .occurrence = self.root, .nested = false }, note },
            );
            return error.DesugarFailed;
        }

        const first = rows[0];
        var bindings: std.ArrayList(Entry) = .empty;
        try bindings.appendSlice(b.allocator, first.bindings);
        for (first.items, 0..) |item, i| {
            switch (item.pattern.kind) {
                .variable => |name| {
                    try bindings.append(b.allocator, .{ .name = name, .symbol = item.occurrence });
                    continue;
                },
                .wildcard => continue,
                .literal => |literal| if (self.known(item.occurrence, literal)) |holds| {
                    if (holds) continue;
                    return try self.compile(rows[1..]);
                },
                .synonym => |s| if (self.called(item.occurrence, s.matcher)) |call| {
                    if (!call.holds) return try self.compile(rows[1..]);
                    return try self.compile(try self.withFirst(rows, .{
                        .items = try self.afterCall(s.arguments, call.holes, first.items[i + 1 ..]),
                        .bindings = bindings.items,
                        .alternative = first.alternative,
                    }));
                },
                .constructor, .view => {},
                .all => unreachable,
            }

            const narrowed = try self.withFirst(rows, .{
                .items = first.items[i..],
                .bindings = bindings.items,
                .alternative = first.alternative,
            });
            return switch (item.pattern.kind) {
                .constructor => try self.split(narrowed, item),
                .view => |v| try self.bindView(narrowed, item, v),
                .literal => |literal| try self.testLiteral(narrowed, item, literal),
                .synonym => |s| try self.testSynonym(narrowed, item, s),
                else => unreachable,
            };
        }

        self.uses[first.alternative] += 1;
        if (self.calls.items.len > 0) self.under_synonym[first.alternative] = true;
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
        const declared = self.lowerer.scope.env.datatypes.get(try self.datatypeOf(rows, occurrence));
        const branches = try b.slice(Tree.Branch, declared.constructors.len);
        for (declared.constructors, branches) |constructor, *branch| {
            const fields = try b.slice(core.SymbolId, constructor.fields.len);
            for (fields, 0..) |*field, i| {
                const name = fieldName(rows, occurrence, constructor.symbol, i) orelse
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
                const this = datatypes.ownerOf(&self.lowerer.env.interner, c.symbol).?;
                const expected = found orelse {
                    found = this;
                    continue;
                };
                if (this != expected) {
                    try self.lowerer.sink.report(
                        .type_mismatch,
                        item.pattern.span,
                        "`{s}` is not a constructor of `{s}`",
                        .{ self.lowerer.env.interner.spelling(c.symbol), self.lowerer.scope.env.datatypes.get(expected).name },
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
                if (c.symbol != constructor) continue :rows;
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
    fn bindView(self: *Matcher, rows: []const Row, item: Item, v: *const Pattern.View) Error!*const Tree {
        const b = self.lowerer.builder;
        const first = rows[0];
        const symbol = try self.lowerer.env.interner.fresh(givenName(v.pattern) orelse "view");
        var items: std.ArrayList(Item) = .empty;
        try push(b.allocator, &items, v.pattern, symbol);
        try items.appendSlice(b.allocator, first.items[1..]);

        const replaced = try self.withFirst(rows, .{ .items = items.items, .bindings = first.bindings, .alternative = first.alternative });
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

        const matching = try self.withFirst(rows, .{ .items = first.items[1..], .bindings = first.bindings, .alternative = first.alternative });
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

    /// Call the matcher of the first row's first item, a synonym. A failed
    /// call drops only that row.
    fn testSynonym(self: *Matcher, rows: []const Row, item: Item, s: Pattern.Synonym) Error!*const Tree {
        const b = self.lowerer.builder;
        const first = rows[0];
        const matcher = s.matcher;

        const holes = try b.slice(core.SymbolId, s.arguments.len);
        const hole_spans = try b.slice(diagnostic.Span, s.arguments.len);
        const prefix = try std.ascii.allocLowerString(b.allocator, self.lowerer.env.interner.spelling(s.symbol));
        for (s.arguments, holes, hole_spans, 0..) |argument, *hole, *span, i| {
            const name = givenName(argument) orelse try b.print("{s}{d}", .{ prefix, i });
            hole.* = try self.lowerer.env.interner.fresh(name);
            span.* = argument.span;
        }

        try self.calls.append(b.allocator, .{ .occurrence = item.occurrence, .matcher = matcher, .holes = holes, .holds = false });
        const failed = try self.compile(rows[1..]);
        _ = self.calls.pop();

        const matching = try self.withFirst(rows, .{
            .items = try self.afterCall(s.arguments, holes, first.items[1..]),
            .bindings = first.bindings,
            .alternative = first.alternative,
        });
        try self.calls.append(b.allocator, .{ .occurrence = item.occurrence, .matcher = matcher, .holes = holes, .holds = true });
        const matched = try self.compile(matching);
        _ = self.calls.pop();

        return try self.node(.{ .synonym = .{
            .occurrence = item.occurrence,
            .matcher = matcher,
            .holes = holes,
            .hole_spans = hole_spans,
            .span = item.pattern.span,
            .matched = matched,
            .failed = failed,
        } });
    }

    /// Returns `rows` with its first row replaced by `first`.
    fn withFirst(self: *const Matcher, rows: []const Row, first: Row) Error![]const Row {
        const replaced = try self.lowerer.builder.dupeSlice(Row, rows);
        replaced[0] = first;
        return replaced;
    }

    /// Returns the items a row continues with once a synonym call binds
    /// `holes`: each argument against its hole, then `rest`.
    fn afterCall(self: *const Matcher, arguments: []const Pattern, holes: []const core.SymbolId, rest: []const Item) Error![]const Item {
        const allocator = self.lowerer.builder.allocator;
        var items: std.ArrayList(Item) = .empty;
        for (arguments, holes) |argument, hole| try push(allocator, &items, argument, hole);
        try items.appendSlice(allocator, rest);
        return items.items;
    }

    /// The call of `matcher` on `occurrence` taken on the current path, if one
    /// was.
    fn called(self: *const Matcher, occurrence: core.SymbolId, matcher: core.SymbolId) ?Call {
        for (self.calls.items) |call| {
            if (call.occurrence == occurrence and call.matcher == matcher) return call;
        }
        return null;
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
            if (c.symbol != constructor) continue;
            const argument = c.arguments[index];
            if (givenName(argument)) |name| return name;
            if (argument.kind != .variable and argument.kind != .wildcard) tested = true;
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
    shared: []const ?Shared,
    no_match: NoMatch,

    fn emit(self: Emitter, tree: *const Tree) Error!core.Term {
        const b = self.lowerer.builder;
        switch (tree.*) {
            .leaf => |leaf| {
                const inner: resolve.Scope = .{ .parent = self.scope, .names = leaf.bindings };
                const otherwise = leaf.otherwise orelse return try self.body(leaf, &inner);
                const guard = self.arms[leaf.alternative].guard.?;
                const condition = try self.lowerer.expression(guard, &inner);
                const matched = try self.body(leaf, &inner);
                return try self.lowerer.builder.choose(&self.lowerer.scope.env.datatypes, condition, try self.emit(otherwise), matched, guard.span);
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
                const function = switch (v.function) {
                    .written => |e| try self.lowerer.expression(e, &inner),
                    .lowered => |term| term,
                };
                const value = try b.application(.{
                    .function = function,
                    .argument = self.occurrence(v.occurrence, v.span),
                    .view = true,
                }, v.span);
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
                return try self.lowerer.builder.choose(&self.lowerer.scope.env.datatypes, condition, try self.emit(l.failed), matched, l.span);
            },
            .synonym => |s| {
                var continuation = try self.emit(s.matched);
                var i = s.holes.len;
                while (i > 0) {
                    i -= 1;
                    continuation = try b.lambda(s.holes[i], continuation, s.hole_spans[i]);
                }
                return try b.applyMany(
                    b.symbol(s.matcher, s.span),
                    &.{ self.occurrence(s.occurrence, s.span), continuation, try self.emit(s.failed) },
                    s.span,
                );
            },
            .fail => return switch (self.no_match) {
                .fallthrough => |term| term,
                .report => unreachable,
            },
        }
    }

    fn occurrence(self: Emitter, symbol: core.SymbolId, span: diagnostic.Span) core.Term {
        if (symbol == self.root and !self.root_bound) return self.scrutinee;
        return self.lowerer.builder.symbol(symbol, span);
    }

    fn body(self: Emitter, leaf: Tree.Leaf, inner: *const resolve.Scope) Error!core.Term {
        const b = self.lowerer.builder;
        const arm = self.arms[leaf.alternative];
        const shared = self.shared[leaf.alternative] orelse return try lowerBody(self.lowerer, arm.body, inner);
        const arguments = try b.slice(core.Term, shared.variables.len);
        for (shared.variables, arguments) |variable, *argument| {
            argument.* = b.symbol(lookup(leaf.bindings, variable.name), self.span);
        }
        return try b.applyMany(b.symbol(shared.symbol, self.span), arguments, self.span);
    }

    fn lookup(bindings: []const Entry, name: []const u8) core.SymbolId {
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.name orelse continue, name)) return binding.symbol;
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
        if (self.isTuple(step)) {
            try w.writeByte('(');
            for (step.fields, 0..) |field, i| {
                if (i > 0) try w.writeAll(", ");
                try self.at(field, false).format(w);
            }
            return w.writeByte(')');
        }
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
        return datatypes.ownerOf(&lowerer.env.interner, step.constructor) == lowerer.scope.env.datatypes.listId();
    }

    fn isTuple(self: Witness, step: Step) bool {
        const env = self.matcher.lowerer.env;
        return datatypes.formOf(&env.interner, &env.datatypes, step.constructor) == .tuple;
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
            .wildcard => try w.writeAll("_"),
            .constructor => |c| {
                try w.writeAll(c.name);
                for (c.arguments) |argument| {
                    try w.writeByte(' ');
                    try (Written{ .pattern = argument, .context = .atom }).format(w);
                }
            },
            .list, .tuple => |elements| {
                const brackets = if (self.pattern.kind == .list) "[]" else "()";
                try w.writeByte(brackets[0]);
                for (elements, 0..) |element, i| {
                    if (i > 0) try w.writeAll(", ");
                    try (Written{ .pattern = element }).format(w);
                }
                try w.writeByte(brackets[1]);
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
            .variable, .wildcard, .list, .tuple, .as, .view, .literal, .node => .atom,
        };
    }
};
