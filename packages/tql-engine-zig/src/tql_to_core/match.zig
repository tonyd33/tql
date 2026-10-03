//! Nested `case` patterns to flat Core `case`.
//!
//! Compiles to a decision tree. Each test switches on the first column the
//! first remaining row tests, and splits over every constructor of that
//! column's datatype, so each Core `case` it emits is exhaustive. A
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
const resolve = @import("resolve.zig");
const desugar = @import("desugar.zig");
const datatypes = core.datatypes;

const Error = desugar.Error;
const Lowerer = desugar.Lowerer;
const ModuleScope = @import("scope.zig").ModuleScope;
const Entry = resolve.Scope.Entry;

const wildcard: cst.Pattern = .{ .kind = .{ .variable = "_" } };

fn isWildcard(name: []const u8) bool {
    return std.mem.eql(u8, name, "_");
}

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
    const b = lowerer.builder;
    const expanded = try b.slice(cst.Case.Alternative, c.alternatives.len);
    for (c.alternatives, expanded) |alternative, *out| {
        out.* = alternative;
        out.pattern = try expand(b, alternative.pattern);
    }
    for (expanded) |alternative| try checkPattern(lowerer, alternative.pattern);

    const root = switch (scrutinee.kind) {
        .symbol => |s| s,
        else => try lowerer.interner.fresh("scrutinee"),
    };

    const rows = try b.slice(Row, expanded.len);
    for (expanded, rows, 0..) |alternative, *row, i| {
        row.* = .{
            .patterns = try b.dupeSlice(cst.Pattern, &.{alternative.pattern}),
            .bindings = &.{},
            .alternative = @intCast(i),
        };
    }

    var matcher: Matcher = .{
        .lowerer = lowerer,
        .alternatives = expanded,
        .span = span,
        .root = root,
        .uses = try b.slice(u32, c.alternatives.len),
    };
    defer matcher.path.deinit(b.allocator);
    @memset(matcher.uses, 0);

    const tree = try matcher.compile(&.{root}, rows);

    for (c.alternatives, matcher.uses) |alternative, uses| {
        if (uses > 0) continue;
        try lowerer.sink.report(
            .type_mismatch,
            alternative.pattern.span,
            "`{f}` is never matched",
            .{Written{ .pattern = alternative.pattern }},
        );
        return error.DesugarFailed;
    }

    const shared = try b.slice(?core.SymbolId, c.alternatives.len);
    var bindings: std.ArrayList(core.Letrec.Binding) = .empty;
    for (expanded, matcher.uses, shared) |alternative, uses, *slot| {
        slot.* = null;
        if (uses < 2) continue;
        const symbol = try lowerer.interner.fresh("alternative");
        slot.* = symbol;
        try bindings.append(b.allocator, .{
            .name = symbol,
            .value = try sharedAlternative(lowerer, alternative, scope, span),
        });
    }

    const emitter: Emitter = .{
        .lowerer = lowerer,
        .alternatives = expanded,
        .scope = scope,
        .span = span,
        .root = root,
        .scrutinee = scrutinee,
        .root_bound = binds(tree, root),
        .shared = shared,
    };
    var term = try emitter.emit(tree);

    // A scrutinee that is not already a name is bound only when an
    // alternative names it.
    if (scrutinee.kind != .symbol and emitter.root_bound) {
        const letrec = try b.slice(core.Letrec.Binding, 1);
        letrec[0] = .{ .name = root, .value = scrutinee };
        term = try b.letrec(letrec, term, span);
    }
    if (bindings.items.len > 0) {
        term = try b.letrec(try bindings.toOwnedSlice(b.allocator), term, span);
    }
    return term;
}

/// Rewrite list and cons patterns as `Cons` and `Nil` constructor patterns.
/// Everything past `caseOf`'s entry sees only variables and constructors.
fn expand(b: core.Builder, pattern: cst.Pattern) Error!cst.Pattern {
    switch (pattern.kind) {
        .variable => return pattern,
        .constructor => |c| {
            const arguments = try b.slice(cst.Pattern, c.arguments.len);
            for (c.arguments, arguments) |argument, *out| out.* = try expand(b, argument);
            return .{
                .kind = .{ .constructor = .{ .name = c.name, .arguments = arguments, .prelude = c.prelude } },
                .span = pattern.span,
            };
        },
        .cons => |c| return try cell(b, try expand(b, c.head), try expand(b, c.tail), pattern.span),
        .list => |elements| {
            var spine = preludePattern("Nil", &.{}, pattern.span);
            var i = elements.len;
            while (i > 0) {
                i -= 1;
                // An inner cell spans its head element.
                const span = if (i == 0) pattern.span else elements[i].span;
                spine = try cell(b, try expand(b, elements[i]), spine, span);
            }
            return spine;
        },
    }
}

fn cell(b: core.Builder, head: cst.Pattern, tail: cst.Pattern, span: diagnostic.Span) Error!cst.Pattern {
    const arguments = try b.slice(cst.Pattern, 2);
    arguments[0] = head;
    arguments[1] = tail;
    return preludePattern("Cons", arguments, span);
}

fn preludePattern(name: []const u8, arguments: []const cst.Pattern, span: diagnostic.Span) cst.Pattern {
    return .{
        .kind = .{ .constructor = .{ .name = name, .arguments = arguments, .prelude = true } },
        .span = span,
    };
}

/// Reject a pattern naming an unknown constructor, giving a constructor the
/// wrong number of arguments, or binding one variable twice.
fn checkPattern(lowerer: *Lowerer, pattern: cst.Pattern) Error!void {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(lowerer.builder.allocator);
    try checkPatternInto(lowerer, pattern, &seen);
}

fn checkPatternInto(
    lowerer: *Lowerer,
    pattern: cst.Pattern,
    seen: *std.ArrayList([]const u8),
) Error!void {
    switch (pattern.kind) {
        .variable => |name| {
            if (isWildcard(name)) return;
            for (seen.items) |earlier| {
                if (!std.mem.eql(u8, earlier, name)) continue;
                try lowerer.sink.report(
                    .duplicate_definition,
                    pattern.span,
                    "`{s}` is bound twice in one pattern",
                    .{name},
                );
                return error.DesugarFailed;
            }
            try seen.append(lowerer.builder.allocator, name);
        },
        .constructor => |c| {
            const constructor = try constructorNamed(lowerer, c, pattern.span);
            if (c.arguments.len != constructor.fields.len) {
                try lowerer.sink.report(
                    .type_mismatch,
                    pattern.span,
                    "`{s}` binds {d} field(s), given {d}",
                    .{ c.name, constructor.fields.len, c.arguments.len },
                );
                return error.DesugarFailed;
            }
            for (c.arguments) |argument| try checkPatternInto(lowerer, argument, seen);
        },
        .list, .cons => unreachable,
    }
}

fn constructorNamed(
    lowerer: *Lowerer,
    c: cst.Pattern.Constructor,
    span: diagnostic.Span,
) Error!*const datatypes.Constructor {
    const found = if (c.prelude)
        lowerer.interner.lookup(.prelude, c.name)
    else
        try lowerer.resolveGlobal(c.name, span);
    if (found) |id| {
        if (lowerer.datatypes.constructorOf(lowerer.interner, id)) |constructor| return constructor;
    }
    try lowerer.sink.report(.unresolved_name, span, "`{s}` is not a constructor", .{c.name});
    return error.DesugarFailed;
}

/// The symbol a constructor pattern names.
///
/// Preconditions:
/// - `checkPattern` accepted the pattern `c` is in.
fn constructorSymbol(scope: *const ModuleScope, c: cst.Pattern.Constructor) core.SymbolId {
    if (c.prelude) return scope.interner.lookup(.prelude, c.name).?;
    return scope.value(c.name).found;
}

/// `\x_1 ... x_n -> body` over the alternative's pattern variables, in the
/// order they are written.
fn sharedAlternative(
    lowerer: *Lowerer,
    alternative: cst.Case.Alternative,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
) Error!core.Term {
    var names: std.ArrayList([]const u8) = .empty;
    try variables(lowerer.builder.allocator, alternative.pattern, &names);

    const entries = try lowerer.builder.slice(Entry, names.items.len);
    for (names.items, entries) |name, *entry| {
        entry.* = .{ .name = name, .symbol = try lowerer.interner.fresh(name) };
    }
    const inner: resolve.Scope = .{ .parent = scope, .names = entries };

    var term = try lowerer.expression(alternative.body, &inner);
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        term = try lowerer.builder.lambda(entries[i].symbol, term, span);
    }
    return term;
}

fn variables(
    allocator: std.mem.Allocator,
    pattern: cst.Pattern,
    out: *std.ArrayList([]const u8),
) Error!void {
    switch (pattern.kind) {
        .variable => |name| if (!isWildcard(name)) try out.append(allocator, name),
        .constructor => |c| for (c.arguments) |argument| try variables(allocator, argument, out),
        .list, .cons => unreachable,
    }
}

/// Whether any leaf of `tree` binds a variable to `occurrence`.
fn binds(tree: *const Tree, occurrence: core.SymbolId) bool {
    switch (tree.*) {
        .leaf => |leaf| {
            for (leaf.bindings) |binding| {
                if (binding.symbol == occurrence) return true;
            }
            return false;
        },
        .test_ => |t| {
            for (t.branches) |branch| {
                if (binds(branch.tree, occurrence)) return true;
            }
            return false;
        },
    }
}

/// The patterns still to match against, one per occurrence, and what the
/// row's variables are already bound to.
const Row = struct {
    patterns: []const cst.Pattern,
    bindings: []const Entry,
    alternative: u32,
};

const Tree = union(enum) {
    leaf: Leaf,
    test_: Test,

    const Leaf = struct {
        alternative: u32,
        bindings: []const Entry,
    };

    /// One branch per constructor of the occurrence's datatype, in tag order.
    const Test = struct {
        occurrence: core.SymbolId,
        branches: []const Branch,
    };

    const Branch = struct {
        constructor: core.SymbolId,
        fields: []const core.SymbolId,
        tree: *const Tree,
    };
};

/// A test taken on the way to the current subtree.
const Step = struct {
    occurrence: core.SymbolId,
    constructor: core.SymbolId,
    fields: []const core.SymbolId,
};

const Matcher = struct {
    lowerer: *Lowerer,
    alternatives: []const cst.Case.Alternative,
    span: diagnostic.Span,
    root: core.SymbolId,
    /// Leaves reaching each alternative.
    uses: []u32,
    path: std.ArrayList(Step) = .empty,

    fn compile(self: *Matcher, occurrences: []const core.SymbolId, rows: []const Row) Error!*const Tree {
        const b = self.lowerer.builder;
        if (rows.len == 0) {
            try self.lowerer.sink.report(
                .type_mismatch,
                self.span,
                "`{f}` is not matched",
                .{Witness{ .matcher = self, .occurrence = self.root, .nested = false }},
            );
            return error.DesugarFailed;
        }

        const first = rows[0];
        const column = for (first.patterns, 0..) |pattern, i| {
            if (pattern.kind == .constructor) break i;
        } else {
            var bindings: std.ArrayList(Entry) = .empty;
            try bindings.appendSlice(b.allocator, first.bindings);
            for (first.patterns, occurrences) |pattern, occurrence| {
                const name = pattern.kind.variable;
                if (isWildcard(name)) continue;
                try bindings.append(b.allocator, .{ .name = name, .symbol = occurrence });
            }
            self.uses[first.alternative] += 1;
            const leaf = try b.allocator.create(Tree);
            leaf.* = .{ .leaf = .{
                .alternative = first.alternative,
                .bindings = try bindings.toOwnedSlice(b.allocator),
            } };
            return leaf;
        };

        const owner = try self.columnOwner(rows, column);
        const declared = self.lowerer.datatypes.get(owner);
        const branches = try b.slice(Tree.Branch, declared.constructors.len);
        for (declared.constructors, branches) |constructor, *branch| {
            const fields = try b.slice(core.SymbolId, constructor.fields.len);
            for (fields, 0..) |*field, i| {
                const name = fieldName(self.lowerer.scope, rows, column, constructor.symbol, i) orelse
                    try b.print("{s}{d}", .{
                        try std.ascii.allocLowerString(b.allocator, self.lowerer.interner.spelling(constructor.symbol)),
                        i,
                    });
                field.* = try self.lowerer.interner.fresh(name);
            }

            const specialized = try self.specialize(rows, column, occurrences[column], constructor.symbol, fields.len);
            const inner = try std.mem.concat(b.allocator, core.SymbolId, &.{
                occurrences[0..column],
                fields,
                occurrences[column + 1 ..],
            });

            try self.path.append(b.allocator, .{
                .occurrence = occurrences[column],
                .constructor = constructor.symbol,
                .fields = fields,
            });
            const subtree = try self.compile(inner, specialized);
            _ = self.path.pop();

            branch.* = .{ .constructor = constructor.symbol, .fields = fields, .tree = subtree };
        }

        const node = try b.allocator.create(Tree);
        node.* = .{ .test_ = .{ .occurrence = occurrences[column], .branches = branches } };
        return node;
    }

    /// The datatype every constructor in `column` belongs to.
    fn columnOwner(self: *Matcher, rows: []const Row, column: usize) Error!datatypes.TypeId {
        var owner: ?datatypes.TypeId = null;
        for (rows) |row| {
            const pattern = row.patterns[column];
            const c = switch (pattern.kind) {
                .constructor => |c| c,
                .variable => continue,
                .list, .cons => unreachable,
            };
            const id = constructorSymbol(self.lowerer.scope, c);
            const this = datatypes.ownerOf(self.lowerer.interner, id).?;
            const expected = owner orelse {
                owner = this;
                continue;
            };
            if (this != expected) {
                try self.lowerer.sink.report(
                    .type_mismatch,
                    pattern.span,
                    "`{s}` is not a constructor of `{s}`",
                    .{ c.name, self.lowerer.datatypes.get(expected).name },
                );
                return error.DesugarFailed;
            }
        }
        return owner.?;
    }

    /// The rows that can match when `column`'s occurrence is built by
    /// `constructor`, with that column replaced by the constructor's fields.
    fn specialize(
        self: *Matcher,
        rows: []const Row,
        column: usize,
        occurrence: core.SymbolId,
        constructor: core.SymbolId,
        arity: usize,
    ) Error![]const Row {
        const b = self.lowerer.builder;
        var out: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            const pattern = row.patterns[column];
            var bindings = row.bindings;
            const arguments: []const cst.Pattern = switch (pattern.kind) {
                .constructor => |c| blk: {
                    if (constructorSymbol(self.lowerer.scope, c) != constructor) continue;
                    break :blk c.arguments;
                },
                .variable => |name| blk: {
                    if (!isWildcard(name)) {
                        bindings = try std.mem.concat(b.allocator, Entry, &.{
                            row.bindings,
                            &.{.{ .name = name, .symbol = occurrence }},
                        });
                    }
                    const wildcards = try b.slice(cst.Pattern, arity);
                    @memset(wildcards, wildcard);
                    break :blk wildcards;
                },
                .list, .cons => unreachable,
            };
            try out.append(b.allocator, .{
                .patterns = try std.mem.concat(b.allocator, cst.Pattern, &.{
                    row.patterns[0..column],
                    arguments,
                    row.patterns[column + 1 ..],
                }),
                .bindings = bindings,
                .alternative = row.alternative,
            });
        }
        return try out.toOwnedSlice(b.allocator);
    }

    /// The step that built `occurrence` on the current path, if one did.
    fn stepFor(self: *const Matcher, occurrence: core.SymbolId) ?Step {
        for (self.path.items) |step| {
            if (step.occurrence == occurrence) return step;
        }
        return null;
    }
};

/// The first variable written for a field. Returns null for a field some row
/// tests but none names, and `_` for a field nothing uses.
fn fieldName(
    scope: *const ModuleScope,
    rows: []const Row,
    column: usize,
    constructor: core.SymbolId,
    index: usize,
) ?[]const u8 {
    var tested = false;
    for (rows) |row| {
        switch (row.patterns[column].kind) {
            .constructor => |c| {
                if (constructorSymbol(scope, c) != constructor) continue;
                switch (c.arguments[index].kind) {
                    .variable => |name| if (!isWildcard(name)) return name,
                    .constructor => tested = true,
                    .list, .cons => unreachable,
                }
            },
            .variable => {},
            .list, .cons => unreachable,
        }
    }
    return if (tested) null else "_";
}

const Emitter = struct {
    lowerer: *Lowerer,
    alternatives: []const cst.Case.Alternative,
    scope: ?*const resolve.Scope,
    span: diagnostic.Span,
    root: core.SymbolId,
    scrutinee: core.Term,
    /// Whether an alternative names the scrutinee.
    root_bound: bool,
    shared: []const ?core.SymbolId,

    fn emit(self: Emitter, tree: *const Tree) Error!core.Term {
        const b = self.lowerer.builder;
        switch (tree.*) {
            .leaf => |leaf| {
                const alternative = self.alternatives[leaf.alternative];
                if (self.shared[leaf.alternative]) |function| {
                    var names: std.ArrayList([]const u8) = .empty;
                    try variables(b.allocator, alternative.pattern, &names);
                    const arguments = try b.slice(core.Term, names.items.len);
                    for (names.items, arguments) |name, *argument| {
                        argument.* = b.symbol(lookup(leaf.bindings, name), self.span);
                    }
                    return try b.applyMany(b.symbol(function, self.span), arguments, self.span);
                }
                const inner: resolve.Scope = .{ .parent = self.scope, .names = leaf.bindings };
                return try self.lowerer.expression(alternative.body, &inner);
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
                const scrutinee = if (t.occurrence == self.root and !self.root_bound)
                    self.scrutinee
                else
                    b.symbol(t.occurrence, self.span);
                return try b.case(scrutinee, alternatives, self.span);
            },
        }
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
        const name = self.matcher.lowerer.interner.spelling(step.constructor);
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
        return datatypes.ownerOf(lowerer.interner, step.constructor) == lowerer.datatypes.listId();
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
    nested: bool = false,

    pub fn format(self: Written, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.pattern.kind) {
            .variable => |name| try w.writeAll(name),
            .constructor => |c| {
                const parenthesize = self.nested and c.arguments.len > 0;
                if (parenthesize) try w.writeByte('(');
                try w.writeAll(c.name);
                for (c.arguments) |argument| {
                    try w.writeByte(' ');
                    try (Written{ .pattern = argument, .nested = true }).format(w);
                }
                if (parenthesize) try w.writeByte(')');
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
                if (self.nested) try w.writeByte('(');
                try (Written{ .pattern = c.head, .nested = c.head.kind == .cons }).format(w);
                try w.writeAll(" : ");
                try (Written{ .pattern = c.tail }).format(w);
                if (self.nested) try w.writeByte(')');
            },
        }
    }
};
