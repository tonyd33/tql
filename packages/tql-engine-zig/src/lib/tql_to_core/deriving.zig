//! Derived instances: the method a class's deriver defines at a datatype.
//!
//! A class names its deriver in its body:
//!
//! ```tql
//! class Functor f where {
//!   map :: (a -> b) -> f a -> f b;
//!   deriving %derive_functor;
//! };
//! data Tree a = Leaf | Node (Tree a) a (Tree a) deriving (Functor);
//! ```
//!
//! `deriving (Functor)` declares `instance Functor Tree`, and the deriver
//! writes its `map` by the datatype's shape:
//!
//! ```tql
//! map[Tree] f x = case x of {
//!   Leaf -> Leaf;
//!   Node l v r -> Node (map f l) (f v) (map f r);
//! };
//! ```
//!
//! The class's defaults define every other method. Which deriver a class
//! names is the library's declaration, so the engine holds no list of
//! derivable classes; it holds only what each deriver writes.
//!
//! ## Comparisons in linear size
//!
//! A derived `eq` or `compare` matches both operands. Matching the second
//! against every constructor gives each pair of constructors an
//! alternative, and a datatype of `n` constructors a method of `n^2`
//! alternatives. Only matching pairs compare fields, so match the second
//! against the first's constructor alone and send the rest to a default:
//!
//! ```tql
//! compare[T] x y = case x of {
//!   C_i xs -> case y of {
//!     C_i ys -> ...the fields...;
//!     _ -> compare (tag[T] x) (tag[T] y);
//!   };
//! };
//! ```
//!
//! `tag[T]` is a local function, `\x -> case x of { C_i _ -> i; }`, bound
//! around the method, so the method stays well typed. `eq`'s default is
//! `False` and needs no tag.
//!
//! ## Over the last parameter
//!
//! `Functor`, `Foldable` and `Traversable` range over a type constructor,
//! so their instance is for the datatype without its last parameter, `a`.
//! A field reaches `a` by its type: as `a` itself, through a tuple's
//! components, through `g τ` with `a` only in `τ` by `g`'s own instance,
//! and, for `map` only, through a function's result. Each `g` it passes
//! through is a wanted of the instance's context, so
//! `data T f a = T (f a)` derives `Functor f => Functor (T f)`. A field
//! that reaches `a` any other way, `a -> Int` say, cannot be derived.

const std = @import("std");
const core = @import("../core.zig");
const diagnostic = @import("../diagnostic.zig");
const classes = core.classes;
const datatypes = core.datatypes;
const types = core.types;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// A deriver resolved against a class, or why it does not fit.
pub const Resolution = union(enum) {
    derived: classes.Derived,
    misfit: Misfit,
};

/// Why a deriver does not fit a class.
pub const Misfit = enum {
    /// The class does not declare the method the deriver defines.
    undeclared,
    /// The class declares the method at another type.
    mistyped,
    /// Defining the method alone does not satisfy the class's `minimal`.
    unsatisfied,
};

/// Resolves `deriver` against `class`: the method it defines must be one
/// `class` declares at the type the deriver defines it at, and defining it
/// alone must satisfy `class`'s `minimal`.
pub fn resolve(env: *core.env.Env, class: classes.Class, deriver: classes.Deriver) Error!Resolution {
    const arena = env.allocator();
    const spelling = deriver.method();
    const index = class.methodNamed(&env.interner, spelling) orelse return .{ .misfit = .undeclared };
    const scheme = env.schemeOf(class.methods[index]).?;
    const traverses = deriver == .derive_traversable;
    const found = if (traverses) try applicative(env, scheme) else null;
    if (!fits(scheme, try expected(env, deriver), if (traverses) 2 else null) or (traverses and found == null)) return .{ .misfit = .mistyped };
    const defined = try arena.alloc(bool, class.methods.len);
    @memset(defined, false);
    defined[index] = true;
    if (!class.minimal.satisfied(defined)) return .{ .misfit = .unsatisfied };
    return .{ .derived = .{ .deriver = deriver, .method = index, .applicative = found } };
}

/// The type `deriver` defines its method at, with the class's parameter as
/// variable 0.
fn expected(env: *core.env.Env, deriver: classes.Deriver) Error!types.Type {
    const arena = env.allocator();
    const v = types.variable_type;
    return switch (deriver) {
        .derive_eq => try types.arrows(arena, &.{ v(0), v(0) }, try env.datatypes.boolType(arena)),
        .derive_ord => try types.arrows(arena, &.{ v(0), v(0) }, try env.datatypes.orderingType(arena)),
        .derive_to_json => try types.func(arena, v(0), try types.constructed(arena, env.datatypes.jsonId(), types.json_spelling, &.{})),
        .derive_functor => try types.arrows(arena, &.{
            try types.func(arena, v(1), v(2)),
            try types.apply(arena, v(0), v(1)),
        }, try types.apply(arena, v(0), v(2))),
        .derive_foldable => try types.arrows(arena, &.{
            try types.arrows(arena, &.{ v(1), v(2) }, v(2)),
            v(2),
            try types.apply(arena, v(0), v(1)),
        }, v(2)),
        .derive_traversable => try types.arrows(arena, &.{
            try types.func(arena, v(1), try types.apply(arena, v(2), v(3))),
            try types.apply(arena, v(0), v(1)),
        }, try types.apply(arena, v(2), try types.apply(arena, v(0), v(3)))),
    };
}

/// Whether `scheme`'s type is `pattern` up to renaming its variables, with
/// variable 0 kept, and its only constraint besides its class's own is on
/// the variable `constrained` renames to.
fn fits(scheme: types.Scheme, pattern: types.Type, constrained: ?types.TypeVar) bool {
    var renaming: [4]?types.TypeVar = @splat(null);
    renaming[0] = 0;
    if (!renamed(pattern, scheme.type, &renaming)) return false;
    const v = constrained orelse return scheme.constraints.len == 1;
    if (scheme.constraints.len != 2) return false;
    const c = types.unalias(scheme.constraints[1].type);
    return c == .variable and c.variable == renaming[v].?;
}

/// Whether `actual` is `pattern` with each variable renamed one to one, as
/// `renaming` records and extends.
fn renamed(pattern: types.Type, actual: types.Type, renaming: []?types.TypeVar) bool {
    const a = types.unalias(actual);
    switch (pattern) {
        .variable => |v| {
            if (a != .variable) return false;
            if (renaming[v]) |r| return r == a.variable;
            for (renaming) |r| if (r) |taken| if (taken == a.variable) return false;
            renaming[v] = a.variable;
            return true;
        },
        .constructor => |c| {
            if (a != .constructor or a.constructor.name != c.name) return false;
            if (a.constructor.arguments.len != c.arguments.len) return false;
            for (c.arguments, a.constructor.arguments) |p, x| if (!renamed(p, x, renaming)) return false;
            return true;
        },
        .function => |f| return a == .function and
            renamed(f.from, a.function.from, renaming) and
            renamed(f.to, a.function.to, renaming),
        .application => |x| return a == .application and
            renamed(x.head, a.application.head, renaming) and
            renamed(x.argument, a.application.argument, renaming),
        .meta, .skolem, .row, .alias => unreachable,
    }
}

/// The `pure` and `ap` of the class `traverse`'s scheme constrains its
/// applicative by, when that class has both at their types.
fn applicative(env: *core.env.Env, traverse: types.Scheme) Error!?classes.Applicative {
    if (traverse.constraints.len != 2) return null;
    const class = env.classes.get(traverse.constraints[1].class).*;
    const pure = class.methodNamed(&env.interner, "pure") orelse return null;
    const ap = class.methodNamed(&env.interner, "ap") orelse return null;
    const arena = env.allocator();
    const v = types.variable_type;
    const pure_type = try types.func(arena, v(1), try types.apply(arena, v(0), v(1)));
    const ap_type = try types.arrows(arena, &.{
        try types.apply(arena, v(0), try types.func(arena, v(1), v(2))),
        try types.apply(arena, v(0), v(1)),
    }, try types.apply(arena, v(0), v(2)));
    if (!fits(env.schemeOf(class.methods[pure]).?, pure_type, null)) return null;
    if (!fits(env.schemeOf(class.methods[ap]).?, ap_type, null)) return null;
    return .{ .pure = class.methods[pure], .ap = class.methods[ap] };
}

/// How a field's type holds the last parameter, `a`.
const Shape = union(enum) {
    /// It does not mention `a`.
    absent,
    /// It is `a`.
    element,
    /// A tuple, holding `a` in its components.
    tuple: struct { constructor: core.SymbolId, components: []const types.Type },
    /// `g τ` with `a` only in `τ`, held through `g`'s instance.
    through: struct { head: types.Type, inner: types.Type },
    /// `σ -> τ` with `a` only in `τ`.
    result: types.Type,
    /// `a` where no deriver reaches it.
    stuck,
};

fn shapeOf(env: *core.env.Env, t: types.Type, last: types.TypeVar) Error!Shape {
    if (!types.mentions(t, last)) return .absent;
    switch (types.unalias(t)) {
        .variable => return .element,
        .function => |f| return if (types.mentions(f.from, last)) .stuck else .{ .result = f.to },
        .constructor => |c| {
            const declared = env.datatypes.get(c.name);
            if (declared.form == .tuple) return .{ .tuple = .{ .constructor = declared.constructors[0].symbol, .components = c.arguments } };
            const init = c.arguments[0 .. c.arguments.len - 1];
            for (init) |argument| if (types.mentions(argument, last)) return .stuck;
            return .{ .through = .{
                .head = try types.constructed(env.allocator(), c.name, c.spelling, init),
                .inner = c.arguments[init.len],
            } };
        },
        .application => |x| return if (types.mentions(x.head, last)) .stuck else .{ .through = .{ .head = x.head, .inner = x.argument } },
        // A constructor field holds no row, metavariable or skolem.
        .row, .meta, .skolem, .alias => unreachable,
    }
}

/// Appends to `out` each type a field of type `field` wants the class at:
/// `field` itself, or for a deriver over the last parameter `last`, each
/// type constructor the field reaches `last` through. Returns the part of
/// `field` that reaches `last` in a way the deriver cannot follow, or null.
pub fn wanteds(
    gpa: Allocator,
    env: *core.env.Env,
    deriver: classes.Deriver,
    field: types.Type,
    last: types.TypeVar,
    out: *std.ArrayList(types.Type),
) Error!?types.Type {
    if (!deriver.overLast()) {
        try out.append(gpa, field);
        return null;
    }
    switch (try shapeOf(env, field, last)) {
        .absent, .element => return null,
        .tuple => |t| {
            for (t.components) |component| {
                if (try wanteds(gpa, env, deriver, component, last, out)) |stuck| return stuck;
            }
            return null;
        },
        .through => |x| {
            try out.append(gpa, x.head);
            return try wanteds(gpa, env, deriver, x.inner, last, out);
        },
        .result => |to| return if (deriver == .derive_functor) try wanteds(gpa, env, deriver, to, last, out) else field,
        .stuck => return field,
    }
}

/// Builds a derived method. For `eq`, `compare` and `to_json`, a field of
/// the type itself, at its own parameters, goes through the method being
/// derived, and any other through its type's own instance.
pub const Derivation = struct {
    builder: core.Builder,
    env: *core.env.Env,
    derived: classes.Derived,
    /// The class's method the deriver defines.
    method: core.SymbolId,
    /// The method being derived.
    itself: core.SymbolId,
    datatype: datatypes.TypeId,
    span: diagnostic.Span,

    const Alternative = core.Case.Alternative;

    pub fn body(self: Derivation) Error!core.Term {
        return switch (self.derived.deriver) {
            .derive_eq, .derive_ord => try self.comparison(),
            .derive_to_json => try self.encoder(),
            .derive_functor => try self.mapper(),
            .derive_foldable => try self.folder(),
            .derive_traversable => try self.traverser(),
        };
    }

    fn constructors(self: Derivation) []const datatypes.Constructor {
        return self.env.datatypes.get(self.datatype).constructors;
    }

    /// The datatype's last parameter, which a deriver over it ranges over.
    fn last(self: Derivation) types.TypeVar {
        return @intCast(self.env.datatypes.get(self.datatype).parameters.len - 1);
    }

    fn shape(self: Derivation, t: types.Type) Error!Shape {
        return try shapeOf(self.env, t, self.last());
    }

    fn fresh(self: Derivation, spelling: []const u8) Error!core.SymbolId {
        return try self.env.interner.fresh(spelling);
    }

    fn binders(self: Derivation, count: usize, spelling: []const u8) Error![]core.SymbolId {
        const out = try self.builder.slice(core.SymbolId, count);
        for (out) |*binder| binder.* = try self.fresh(spelling);
        return out;
    }

    fn symbol(self: Derivation, id: core.SymbolId) core.Term {
        return self.builder.symbol(id, self.span);
    }

    fn symbols(self: Derivation, ids: []const core.SymbolId) Error![]core.Term {
        const out = try self.builder.slice(core.Term, ids.len);
        for (ids, out) |id, *term| term.* = self.symbol(id);
        return out;
    }

    fn apply(self: Derivation, function: core.Term, arguments: []const core.Term) Error!core.Term {
        return try self.builder.applyMany(function, arguments, self.span);
    }

    fn unpack(self: Derivation, value: core.Term, constructor: core.SymbolId, zs: []const core.SymbolId, body_term: core.Term) Error!core.Term {
        return try self.builder.unpack(value, constructor, zs, body_term, self.span);
    }

    /// `\ps x -> case x of { C_i xs -> ...; }`, each alternative's body as
    /// `alternativeBody` builds it from `ps`, `C_i` and `xs`.
    fn perConstructor(self: Derivation, parameters: []const core.SymbolId, comptime alternativeBody: fn (Derivation, []const core.SymbolId, datatypes.Constructor, []const core.SymbolId) Error!core.Term) Error!core.Term {
        const b = self.builder;
        const x = parameters[parameters.len - 1];
        const alternatives = try b.slice(Alternative, self.constructors().len);
        for (self.constructors(), alternatives) |c, *alternative| {
            const xs = try self.binders(c.fields.len, "a");
            alternative.* = .{ .constructor = c.symbol, .binders = xs, .body = try alternativeBody(self, parameters, c, xs) };
        }
        return try b.abstract(parameters, try b.case(self.symbol(x), alternatives, self.span));
    }

    /// `let { tag = \x -> case x of { C_i _ -> i; }; } in \x y -> ...`, a
    /// derived `eq` or `compare`. Compares constructors, then fields left
    /// to right. Every field but the last is compared as a `case` scrutinee
    /// and the last in tail position.
    fn comparison(self: Derivation) Error!core.Term {
        const b = self.builder;
        const x = try self.fresh("x");
        const y = try self.fresh("y");
        const several = self.constructors().len > 1;
        const tag: ?core.SymbolId = if (several and self.derived.deriver == .derive_ord) try self.fresh("tag") else null;
        const outer = try b.slice(Alternative, self.constructors().len);
        for (self.constructors(), outer) |c, *alternative| {
            const xs = try self.binders(c.fields.len, "a");
            const ys = try self.binders(c.fields.len, "b");
            const matched = try b.dupeSlice(Alternative, &.{.{ .constructor = c.symbol, .binders = ys, .body = try self.fields(c.fields, xs, ys) }});
            const unmatched: ?core.Term = if (!several) null else if (tag) |t| try self.apply(self.symbol(self.method), &.{
                try self.apply(self.symbol(t), &.{self.symbol(x)}),
                try self.apply(self.symbol(t), &.{self.symbol(y)}),
            }) else self.constant(self.env.datatypes.boolConstructor(false));
            alternative.* = .{
                .constructor = c.symbol,
                .binders = xs,
                .body = try b.caseOf(.{ .scrutinee = self.symbol(y), .alternatives = matched, .default = unmatched }, self.span),
            };
        }
        const compared = try b.abstract(&.{ x, y }, try b.case(self.symbol(x), outer, self.span));
        const t = tag orelse return compared;
        return try b.let(t, try self.perConstructor(&.{try self.fresh("x")}, tagOf), compared, self.span);
    }

    fn tagOf(self: Derivation, _: []const core.SymbolId, c: datatypes.Constructor, _: []const core.SymbolId) Error!core.Term {
        return self.builder.literal(.{ .number = c.tag }, self.span);
    }

    /// The answer for two fields that differ, the first ordering before the
    /// second or not.
    fn differ(self: Derivation, earlier: bool) core.Term {
        return switch (self.derived.deriver) {
            .derive_eq => self.constant(self.env.datatypes.boolConstructor(false)),
            else => self.constant(self.env.datatypes.orderingConstructor(if (earlier) .lt else .gt)),
        };
    }

    /// The answer for two values whose fields all compare equal.
    fn same(self: Derivation) core.Term {
        return switch (self.derived.deriver) {
            .derive_eq => self.constant(self.env.datatypes.boolConstructor(true)),
            else => self.constant(self.env.datatypes.orderingConstructor(.eq)),
        };
    }

    fn constant(self: Derivation, c: datatypes.Constructor) core.Term {
        return self.symbol(c.symbol);
    }

    /// Compares `xs` with `ys` pairwise, stopping at the first pair that
    /// decides.
    fn fields(self: Derivation, field_types: []const types.Type, xs: []const core.SymbolId, ys: []const core.SymbolId) Error!core.Term {
        if (field_types.len == 0) return self.same();
        const b = self.builder;
        const final = field_types.len - 1;
        var result = try self.field(field_types[final], &.{ xs[final], ys[final] });
        var i = final;
        while (i > 0) {
            i -= 1;
            const compared = try self.field(field_types[i], &.{ xs[i], ys[i] });
            result = switch (self.derived.deriver) {
                .derive_eq => try b.choose(&self.env.datatypes, compared, self.differ(true), result, self.span),
                else => try b.chooseOrder(&self.env.datatypes, compared, .{ self.differ(true), result, self.differ(false) }, self.span),
            };
        }
        return result;
    }

    /// The method applied to `values`, each a field of type `t`.
    fn field(self: Derivation, t: types.Type, values: []const core.SymbolId) Error!core.Term {
        const function = if (self.isItself(t)) self.itself else self.method;
        return try self.apply(self.symbol(function), try self.symbols(values));
    }

    /// Whether `t` is the type being derived at its own parameters, in order.
    fn isItself(self: Derivation, t: types.Type) bool {
        if (t != .constructor or t.constructor.name != self.datatype) return false;
        for (t.constructor.arguments, 0..) |argument, i| {
            if (argument != .variable or argument.variable != i) return false;
        }
        return true;
    }

    /// `\x -> case x of { C_i xs -> ... }`, writing `C_i xs` as `Json` by
    /// the datatype's shape: with one constructor, a lone field is itself and
    /// any other number an array; with several, all without fields, the
    /// constructor's name; otherwise an object of the `tag` and the
    /// `contents`, the fields written as with one constructor.
    fn encoder(self: Derivation) Error!core.Term {
        return try self.perConstructor(&.{try self.fresh("x")}, encoded);
    }

    fn encoded(self: Derivation, _: []const core.SymbolId, c: datatypes.Constructor, xs: []const core.SymbolId) Error!core.Term {
        const all = self.constructors();
        if (all.len == 1) return try self.contents(c.fields, xs);
        const name = self.env.interner.spelling(c.symbol);
        const nullary = for (all) |other| {
            if (other.fields.len > 0) break false;
        } else true;
        if (nullary) return try self.builder.jsonString(&self.env.datatypes, name, self.span);
        return try self.tagged(name, c.fields, xs);
    }

    /// `JObject [("tag", JString name), ("contents", ...)]`, without
    /// `contents` when there are no fields.
    fn tagged(self: Derivation, name: []const u8, field_types: []const types.Type, xs: []const core.SymbolId) Error!core.Term {
        const b = self.builder;
        const tag: core.Builder.Member = .{ .key = "tag", .value = try b.jsonString(&self.env.datatypes, name, self.span) };
        if (xs.len == 0) return try b.jsonObject(&self.env.datatypes, &.{tag}, self.span);
        return try b.jsonObject(&self.env.datatypes, &.{ tag, .{ .key = "contents", .value = try self.contents(field_types, xs) } }, self.span);
    }

    /// A lone field itself, and any other number an array.
    fn contents(self: Derivation, field_types: []const types.Type, xs: []const core.SymbolId) Error!core.Term {
        if (xs.len == 1) return try self.field(field_types[0], &.{xs[0]});
        const items = try self.builder.slice(core.Term, xs.len);
        for (field_types, xs, items) |t, x, *item| item.* = try self.field(t, &.{x});
        return try self.builder.jsonArray(&self.env.datatypes, items, self.span);
    }

    /// `\f x -> case x of { C_i ys -> C_i ...; }`, mapping each field by its
    /// type.
    fn mapper(self: Derivation) Error!core.Term {
        return try self.perConstructor(&.{ try self.fresh("f"), try self.fresh("x") }, mapped);
    }

    fn mapped(self: Derivation, parameters: []const core.SymbolId, c: datatypes.Constructor, ys: []const core.SymbolId) Error!core.Term {
        return try self.mapAll(c.symbol, c.fields, ys, parameters[0]);
    }

    /// `constructor` applied to `values`, of types `ts`, each mapped by `f`.
    fn mapAll(self: Derivation, constructor: core.SymbolId, ts: []const types.Type, values: []const core.SymbolId, f: core.SymbolId) Error!core.Term {
        const out = try self.builder.slice(core.Term, ts.len);
        for (ts, values, out) |t, v, *m| m.* = try self.mapField(t, f, self.symbol(v));
        return try self.apply(self.symbol(constructor), out);
    }

    /// `value`, of type `t`, with `f` applied at each element in it.
    fn mapField(self: Derivation, t: types.Type, f: core.SymbolId, value: core.Term) Error!core.Term {
        switch (try self.shape(t)) {
            .absent => return value,
            .element => return try self.apply(self.symbol(f), &.{value}),
            .result => |to| {
                const z = try self.fresh("z");
                return try self.builder.lambda(z, try self.mapField(to, f, try self.apply(value, &.{self.symbol(z)})), self.span);
            },
            .tuple => |tuple| {
                const zs = try self.binders(tuple.components.len, "z");
                return try self.unpack(value, tuple.constructor, zs, try self.mapAll(tuple.constructor, tuple.components, zs, f));
            },
            .through => |x| return try self.apply(self.symbol(self.method), &.{ try self.elementwise(x.inner, f), value }),
            .stuck => unreachable,
        }
    }

    /// `\f z x -> case x of { C_i ys -> ...; }`, folding each field by its
    /// type, right to left, into `z`.
    fn folder(self: Derivation) Error!core.Term {
        return try self.perConstructor(&.{ try self.fresh("f"), try self.fresh("z"), try self.fresh("x") }, folded);
    }

    fn folded(self: Derivation, parameters: []const core.SymbolId, c: datatypes.Constructor, ys: []const core.SymbolId) Error!core.Term {
        return try self.foldAll(c.fields, ys, parameters[0], self.symbol(parameters[1]));
    }

    /// `values`, of types `ts`, folded by `f` right to left into `acc`.
    fn foldAll(self: Derivation, ts: []const types.Type, values: []const core.SymbolId, f: core.SymbolId, acc: core.Term) Error!core.Term {
        var result = acc;
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            result = try self.foldField(ts[i], f, self.symbol(values[i]), result);
        }
        return result;
    }

    /// `value`, of type `t`, folded into `acc` by `f` at each element in it.
    fn foldField(self: Derivation, t: types.Type, f: core.SymbolId, value: core.Term, acc: core.Term) Error!core.Term {
        switch (try self.shape(t)) {
            .absent => return acc,
            .element => return try self.apply(self.symbol(f), &.{ value, acc }),
            .tuple => |tuple| {
                const zs = try self.binders(tuple.components.len, "z");
                return try self.unpack(value, tuple.constructor, zs, try self.foldAll(tuple.components, zs, f, acc));
            },
            .through => |x| return try self.apply(self.symbol(self.method), &.{ try self.elementwise(x.inner, f), acc, value }),
            // Deriving rejects a function that mentions the last parameter.
            .result, .stuck => unreachable,
        }
    }

    /// `\f x -> case x of { C_i ys -> ...; }`, rebuilding each constructor
    /// from its fields, traversing those that mention the last parameter
    /// left to right.
    fn traverser(self: Derivation) Error!core.Term {
        return try self.perConstructor(&.{ try self.fresh("f"), try self.fresh("x") }, traversed);
    }

    fn traversed(self: Derivation, parameters: []const core.SymbolId, c: datatypes.Constructor, ys: []const core.SymbolId) Error!core.Term {
        return try self.rebuild(c.symbol, c.fields, ys, parameters[0]);
    }

    /// `constructor` applied to `values`, of types `ts`, in the applicative:
    /// `ap (... ap (pure (\bs -> constructor ...)) t1 ...) tn`, with one
    /// `ti` for each value that mentions the last parameter.
    fn rebuild(self: Derivation, constructor: core.SymbolId, ts: []const types.Type, values: []const core.SymbolId, f: core.SymbolId) Error!core.Term {
        const b = self.builder;
        const app = self.derived.applicative.?;
        var bound: std.ArrayList(core.SymbolId) = .empty;
        var actions: std.ArrayList(core.Term) = .empty;
        const arguments = try b.slice(core.Term, ts.len);
        for (ts, values, arguments) |t, value, *argument| {
            if (try self.shape(t) == .absent) {
                argument.* = self.symbol(value);
                continue;
            }
            const result = try self.fresh("b");
            try bound.append(b.allocator, result);
            try actions.append(b.allocator, try self.traverseField(t, f, self.symbol(value)));
            argument.* = self.symbol(result);
        }
        const built = try self.apply(self.symbol(constructor), arguments);
        var result = try self.apply(self.symbol(app.pure), &.{try b.abstract(bound.items, built)});
        for (actions.items) |action| result = try self.apply(self.symbol(app.ap), &.{ result, action });
        return result;
    }

    /// `value`, of type `t`, traversed by `f` at each element in it.
    fn traverseField(self: Derivation, t: types.Type, f: core.SymbolId, value: core.Term) Error!core.Term {
        switch (try self.shape(t)) {
            .element => return try self.apply(self.symbol(f), &.{value}),
            .tuple => |tuple| {
                const zs = try self.binders(tuple.components.len, "z");
                return try self.unpack(value, tuple.constructor, zs, try self.rebuild(tuple.constructor, tuple.components, zs, f));
            },
            .through => |x| return try self.apply(self.symbol(self.method), &.{ try self.elementwise(x.inner, f), value }),
            // `rebuild` traverses only fields that mention the last
            // parameter, and deriving rejects a function that does.
            .absent, .result, .stuck => unreachable,
        }
    }

    /// The function the class's method takes to act at each element of a
    /// field of type `inner`: `f` itself when `inner` is the last parameter.
    fn elementwise(self: Derivation, inner: types.Type, f: core.SymbolId) Error!core.Term {
        if (try self.shape(inner) == .element) return self.symbol(f);
        const w = try self.fresh("w");
        return switch (self.derived.deriver) {
            .derive_functor => try self.builder.lambda(w, try self.mapField(inner, f, self.symbol(w)), self.span),
            .derive_traversable => try self.builder.lambda(w, try self.traverseField(inner, f, self.symbol(w)), self.span),
            .derive_foldable => blk: {
                const acc = try self.fresh("acc");
                break :blk try self.builder.abstract(&.{ w, acc }, try self.foldField(inner, f, self.symbol(w), self.symbol(acc)));
            },
            .derive_eq, .derive_ord, .derive_to_json => unreachable,
        };
    }
};
