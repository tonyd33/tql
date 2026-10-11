//! Newtype erasure: the constructor of a `newtype` becomes the identity, and
//! matching on it binds the field without forcing the value.

const std = @import("std");
const core = @import("../core.zig");
const datatypes = core.datatypes;

const Allocator = std.mem.Allocator;

/// Erase every `newtype` constructor from `program`'s definitions.
///
/// Postconditions:
/// - No term names a `newtype` constructor.
pub fn program(p: *core.Program) Allocator.Error!void {
    var erasure: Erasure = .{ .env = &p.env };
    const builder: core.Builder = .{ .allocator = p.env.allocator() };
    var definitions: core.Rebuilt(core.Definition) = .{ .original = p.definitions };
    for (p.definitions, 0..) |d, i| {
        const body = try erasure.term(d.body);
        try definitions.set(builder, i, .{ .symbol = d.symbol, .body = body, .span = d.span }, !core.same(body, d.body));
    }
    if (definitions.copy) |copy| p.definitions = copy;
}

const Erasure = struct {
    env: *core.env.Env,

    fn isNewtype(self: *const Erasure, constructor: core.SymbolId) bool {
        return datatypes.formOf(&self.env.interner, &self.env.datatypes, constructor) == .newtype;
    }

    /// `t` with `C e` as `e`, `C` as the identity, each `case e of
    /// { C x -> b }` as `let x = e in b`, and each `case e of y { C x -> b }`
    /// as `let y = e in let x = y in b`. Shares every subtree with nothing
    /// erased.
    fn term(self: *Erasure, t: core.Term) Allocator.Error!core.Term {
        const builder: core.Builder = .{ .allocator = self.env.allocator() };
        switch (t.kind) {
            .symbol => |id| {
                if (!self.isNewtype(id)) return t;
                const x = try self.env.interner.fresh("x");
                return try builder.lambda(x, builder.symbol(x, t.span), t.span);
            },
            .apply => |a| if (a.function.kind == .symbol and self.isNewtype(a.function.kind.symbol)) return try self.term(a.argument),
            .case => |c| if (c.alternatives.len > 0 and self.isNewtype(c.alternatives[0].constructor)) {
                const field = c.alternatives[0].binders[0];
                const scrutinee = try self.term(c.scrutinee);
                const body = try self.term(c.alternatives[0].body);
                const binder = c.binder orelse return try builder.let(field, scrutinee, body, t.span);
                return try builder.lets(&.{
                    .{ .name = binder, .value = scrutinee },
                    .{ .name = field, .value = builder.symbol(binder, t.span) },
                }, body, t.span);
            },
            else => {},
        }
        return try core.mapChildren(builder, t, self, term);
    }
};
