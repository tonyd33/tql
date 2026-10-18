//! Dictionary passing: the wanteds inference raises, the scopes that solve
//! them, and the Core their evidence becomes.
//!
//! Inference applies each use of a constrained name to one evidence variable
//! per constraint, and raises a wanted for each in the frame it is
//! in. A frame is one generalized body: its givens are the dictionaries it
//! binds, and solving a wanted there binds its evidence variable with a
//! `let` around the body, to a dictionary in scope, a superclass selected
//! from one, or an instance applied to the evidence for its context.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const classes = core.classes;
const types = core.types;

const deriving = @import("../deriving.zig");
const primitives = @import("../primitives.zig");

const Allocator = std.mem.Allocator;

/// The frame enclosing every other. What is solved here is bound by
/// top-level definitions.
pub const top: u32 = 0;

/// A dictionary in scope: a parameter of an enclosing generalized body, or of
/// an instance's dictionary.
pub const Given = classes.Given(core.SymbolId);

/// `class type`, owed by the frame it is in.
pub const Wanted = struct {
    class: classes.ClassId,
    type: types.Type,
    evidence: core.SymbolId,
    origin: diagnostic.Span,
};

/// A constraint solved in a frame, and the variable its evidence is bound to.
pub const Solved = struct {
    class: classes.ClassId,
    type: types.Type,
    evidence: core.SymbolId,
};

/// One generalized body: an implication, whose givens hold where its
/// wanteds are solved.
pub const Frame = struct {
    parent: ?u32,
    /// Its level. A skolem at this level or deeper is one of its own.
    level: u32,
    givens: std.ArrayList(Given) = .empty,
    /// Raised here or floated in from a frame inside, and not yet solved.
    wanteds: std.ArrayList(Wanted) = .empty,
    /// Evidence solved here, in the order it was solved.
    bindings: std.ArrayList(core.Letrec.Binding) = .empty,
    /// Each constraint solved here, its type settled, and its evidence
    /// variable.
    solved: std.ArrayList(Solved) = .empty,
    /// The definition whose signature the body is checked against, if any.
    signature: ?core.SymbolId = null,
    /// The instance whose superclasses are solved here, if any.
    instance: ?classes.InstanceId = null,
};

pub const Table = struct {
    gpa: Allocator,
    frames: std.ArrayList(Frame) = .empty,

    pub fn init(gpa: Allocator) Allocator.Error!Table {
        var table: Table = .{ .gpa = gpa };
        _ = try table.frame(null, 0);
        return table;
    }

    pub fn deinit(self: *Table) void {
        for (self.frames.items) |*f| {
            f.givens.deinit(self.gpa);
            f.wanteds.deinit(self.gpa);
            f.bindings.deinit(self.gpa);
            f.solved.deinit(self.gpa);
        }
        self.frames.deinit(self.gpa);
    }

    pub fn frame(self: *Table, parent: ?u32, level: u32) Allocator.Error!u32 {
        try self.frames.append(self.gpa, .{ .parent = parent, .level = level });
        return @intCast(self.frames.items.len - 1);
    }

    pub fn get(self: *Table, at: u32) *Frame {
        return &self.frames.items[at];
    }

    pub fn give(self: *Table, at: u32, given: Given) Allocator.Error!void {
        try self.frames.items[at].givens.append(self.gpa, given);
    }

    pub fn want(self: *Table, at: u32, wanted: Wanted) Allocator.Error!void {
        try self.frames.items[at].wanteds.append(self.gpa, wanted);
    }

    /// The evidence variable of `class t`, `t` settled, when frame `at` or one
    /// enclosing it has solved it.
    pub fn solvedIn(self: *Table, at: u32, class: classes.ClassId, t: types.Type) ?core.SymbolId {
        var current: ?u32 = at;
        while (current) |f| : (current = self.frames.items[f].parent) {
            for (self.frames.items[f].solved.items) |s| {
                if (s.class == class and types.eql(s.type, t)) return s.evidence;
            }
        }
        return null;
    }

    pub fn solve(self: *Table, at: u32, solved: Solved) Allocator.Error!void {
        try self.frames.items[at].solved.append(self.gpa, solved);
    }

    /// Removes every wanted of frame `at`. The caller owns the result.
    pub fn takeAll(self: *Table, at: u32) std.ArrayList(Wanted) {
        const wanteds = self.frames.items[at].wanteds;
        self.frames.items[at].wanteds = .empty;
        return wanteds;
    }

    pub fn bind(self: *Table, at: u32, symbol: core.SymbolId, term: core.Term) Allocator.Error!void {
        try self.frames.items[at].bindings.append(self.gpa, .{ .name = symbol, .value = term });
    }

    /// `body` inside a `let` for each binding of frame `at`.
    pub fn wrap(self: *Table, builder: core.Builder, at: u32, body: core.Term) Allocator.Error!core.Term {
        return try builder.lets(self.frames.items[at].bindings.items, body, body.span);
    }

    /// The givens in scope inside frame `at`, innermost first, as evidence
    /// terms at `span`.
    pub fn scope(
        self: *Table,
        builder: core.Builder,
        at: u32,
        span: diagnostic.Span,
        out: *std.ArrayList(classes.Given(core.Term)),
    ) Allocator.Error!void {
        out.clearRetainingCapacity();
        var current: ?u32 = at;
        while (current) |f| : (current = self.frames.items[f].parent) {
            for (self.frames.items[f].givens.items) |g| {
                try out.append(self.gpa, .{ .class = g.class, .type = g.type, .evidence = builder.symbol(g.evidence, span) });
            }
        }
    }
};

/// A `solve` sink building Core evidence terms at `span`.
pub fn Sink(comptime Leaf: type) type {
    return struct {
        builder: core.Builder,
        /// Where the evidence's symbols are interned.
        env: *core.env.Env,
        span: diagnostic.Span,
        leaves: Leaf,

        const Self = @This();
        pub const Evidence = core.Term;
        pub const Error = Allocator.Error;

        pub fn select(self: Self, selector: core.SymbolId, of: core.Term) Error!core.Term {
            return try self.builder.apply(self.builder.symbol(selector, self.span), of, self.span);
        }

        pub fn instance(self: Self, id: classes.InstanceId, context: []const core.Term) Error!core.Term {
            const dictionary = self.builder.symbol(self.env.classes.instance(id).dictionary, self.span);
            return try self.builder.applyMany(dictionary, context, self.span);
        }

        pub fn row(self: Self, fields: []const types.Type.Field, evidence: []const core.Term, tail: ?core.Term) Error!core.Term {
            const b = self.builder;
            const insert = b.symbol(try primitives.elaboratedSymbol(self.env, .record_insert), self.span);
            var result = tail orelse b.symbol(try primitives.emptyRecordSymbol(self.env), self.span);
            for (fields, evidence) |f, e| {
                result = try b.applyMany(insert, &.{ b.literal(.{ .string = f.label }, self.span), e, result }, self.span);
            }
            return result;
        }

        pub fn derived(self: Self, class: classes.ClassId, all: core.Term) Error!core.Term {
            return try self.builder.apply(self.builder.symbol(self.env.classes.get(class).record.?, self.span), all, self.span);
        }

        pub fn leaf(self: Self, class: classes.ClassId, t: types.Type) Error!?core.Term {
            return try self.leaves.leaf(class, t, self.span);
        }
    };
}

/// Each class's selectors, and each of `instances`' dictionary: a function
/// of its parameters, with its frame's bindings around its class's
/// constructor applied to its superclasses' evidence and its methods.
pub fn dictionaries(
    builder: core.Builder,
    registry: *const classes.Registry,
    env: *core.env.Env,
    table: *Table,
    instances: []const Instance,
    out: *std.ArrayList(core.Definition),
    gpa: Allocator,
) Allocator.Error!void {
    for (registry.classes.items) |class| {
        if (class.role == .all) {
            for (class.selectors, registry.get(class.role.all).selectors) |lifted, selector| {
                try out.append(gpa, try mapped(builder, env, lifted.symbol, selector.symbol, class.span));
            }
        }
        if (class.record) |record| try out.append(gpa, .{ .symbol = record, .body = try recordDictionary(builder, registry, env, class), .span = class.span });
        const constructor = class.constructor orelse continue;
        const fields = class.selectors.len + class.methods.len;
        for (class.selectors, 0..) |selector, i| try out.append(gpa, try field(builder, env, selector.symbol, constructor, fields, i, class.span));
        for (class.methods, class.selectors.len..) |method, i| try out.append(gpa, try field(builder, env, method, constructor, fields, i, class.span));
    }

    for (instances) |built| {
        const instance = registry.instance(built.id);
        const class = registry.get(instance.class);
        const span = instance.span;
        const arguments = try builder.slice(core.Term, built.parameters.len);
        for (built.parameters, arguments) |p, *argument| argument.* = builder.symbol(p, span);

        var body = builder.symbol(class.constructor.?, span);
        for (built.superclasses) |s| body = try builder.apply(body, builder.symbol(s, span), span);
        for (instance.methods) |implementation| {
            body = try builder.apply(body, try builder.applyMany(builder.symbol(implementation, span), arguments, span), span);
        }
        try out.append(gpa, .{
            .symbol = instance.dictionary,
            .body = try builder.abstract(built.parameters, try table.wrap(builder, built.frame, body)),
            .span = span,
        });
    }
}

/// `map[C,S] = map super[C,S]`, selecting `All S`'s evidence from
/// `All C`'s.
fn mapped(b: core.Builder, env: *core.env.Env, symbol: core.SymbolId, selector: core.SymbolId, span: diagnostic.Span) Allocator.Error!core.Definition {
    const map = b.symbol(try primitives.elaboratedSymbol(env, .map), span);
    return .{ .symbol = symbol, .body = try b.apply(map, b.symbol(selector, span), span), .span = span };
}

/// `record[C] = \d -> letrec r = dict[C] .. in r`, `class`'s dictionary at a
/// record from `d`, `All C`'s evidence at its row: each superclass's
/// `record[S]` at its evidence selected from `d`, the method the deriver
/// defines, and the class's defaults for the rest.
///
/// Preconditions:
/// - `class` has a `record[C]`.
fn recordDictionary(b: core.Builder, registry: *const classes.Registry, env: *core.env.Env, class: classes.Class) Allocator.Error!core.Term {
    const span = class.span;
    const d = try env.interner.fresh("d");
    const itself = try env.interner.fresh("r");
    var dictionary = b.symbol(class.constructor.?, span);
    for (class.selectors, registry.get(class.role.declared).selectors) |selector, lifted| {
        const evidence = try b.apply(b.symbol(lifted.symbol, span), b.symbol(d, span), span);
        dictionary = try b.apply(dictionary, try b.apply(b.symbol(registry.get(selector.superclass).record.?, span), evidence, span), span);
    }
    const derived = class.deriver.?;
    for (class.defaults, class.methods, 0..) |default, method, i| {
        const slot = if (i == derived.method)
            try deriving.recordMethod(b, env, derived.deriver, method, d, span)
        else
            try b.apply(b.symbol(default.?, span), b.symbol(itself, span), span);
        dictionary = try b.apply(dictionary, slot, span);
    }
    const bindings = try b.dupeSlice(core.Letrec.Binding, &.{.{ .name = itself, .value = dictionary }});
    return try b.lambda(d, try b.letrec(bindings, b.symbol(itself, span), span), span);
}

/// An instance, and the frame its superclasses are solved in.
pub const Instance = struct {
    id: classes.InstanceId,
    frame: u32,
    /// One per requirement of its context, in order.
    parameters: []const core.SymbolId,
    /// One per selector of its class, in order.
    superclasses: []const core.SymbolId,
};

/// Each symbol to replace, by its replacement.
pub const Replacements = std.AutoHashMapUnmanaged(core.SymbolId, core.Term);

/// `t` with each symbol `replacements` has an entry for replaced by it.
/// Shares every subtree with nothing replaced.
pub fn substitute(
    builder: core.Builder,
    t: core.Term,
    replacements: *const Replacements,
) Allocator.Error!core.Term {
    const replacer: Replacer = .{ .builder = builder, .replacements = replacements };
    return try replacer.term(t);
}

const Replacer = struct {
    builder: core.Builder,
    replacements: *const Replacements,

    fn term(self: Replacer, t: core.Term) Allocator.Error!core.Term {
        return switch (t.kind) {
            .symbol => |id| self.replacements.get(id) orelse t,
            else => try core.mapChildren(self.builder, t, self, term),
        };
    }
};

/// `symbol = \d -> case d of { constructor f_0 .. f_n -> f_index }`.
fn field(
    builder: core.Builder,
    env: *core.env.Env,
    symbol: core.SymbolId,
    constructor: core.SymbolId,
    count: usize,
    index: usize,
    span: diagnostic.Span,
) Allocator.Error!core.Definition {
    const dictionary = try env.interner.fresh("d");
    const binders = try builder.slice(core.SymbolId, count);
    for (binders, 0..) |*binder, i| binder.* = try env.interner.fresh(if (i == index) "m" else "_");
    const selected = try builder.unpack(builder.symbol(dictionary, span), constructor, binders, builder.symbol(binders[index], span), span);
    return .{
        .symbol = symbol,
        .body = try builder.lambda(dictionary, selected, span),
        .span = span,
    };
}
