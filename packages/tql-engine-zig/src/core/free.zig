//! Which symbols a Core term mentions.
//!
//! Every binder is globally unique, interned once by resolution, so two
//! binders never share a SymbolId and a bound name cannot shadow another. No
//! walk here tracks scope.

const std = @import("std");
const core = @import("../core.zig");

const Allocator = std.mem.Allocator;

/// How a symbol appears in a term.
pub const Role = enum { use, binder };

fn VisitError(comptime visit: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(visit)).@"fn".return_type.?).error_union.error_set;
}

/// Visit every symbol in `term`, in source order, until `visit` returns true.
/// Returns whether it did.
pub fn anyMention(term: core.Term, context: anytype, comptime visit: anytype) VisitError(visit)!bool {
    switch (term.kind) {
        .literal => return false,
        .symbol => |symbol| return try visit(context, symbol, .use),
        .lambda => |lambda| {
            if (try visit(context, lambda.parameter, .binder)) return true;
            return try anyMention(lambda.body, context, visit);
        },
        .apply => |apply| {
            if (try anyMention(apply.function, context, visit)) return true;
            return try anyMention(apply.argument, context, visit);
        },
        .case => |case_term| {
            if (try anyMention(case_term.scrutinee, context, visit)) return true;
            for (case_term.alternatives) |alternative| {
                for (alternative.binders) |binder| {
                    if (try visit(context, binder, .binder)) return true;
                }
                if (try anyMention(alternative.body, context, visit)) return true;
            }
            if (case_term.default) |default| return try anyMention(default, context, visit);
            return false;
        },
        .let => |let| {
            if (try anyMention(let.value, context, visit)) return true;
            if (try visit(context, let.name, .binder)) return true;
            return try anyMention(let.body, context, visit);
        },
        .letrec => |letrec| {
            for (letrec.bindings) |binding| {
                if (try visit(context, binding.name, .binder)) return true;
            }
            for (letrec.bindings) |binding| {
                if (try anyMention(binding.value, context, visit)) return true;
            }
            return try anyMention(letrec.body, context, visit);
        },
    }
}

/// Whether `term` reads `symbol`.
pub fn occurs(term: core.Term, symbol: core.SymbolId) bool {
    return anyMention(term, symbol, isUseOf) catch |err| switch (err) {};
}

fn isUseOf(symbol: core.SymbolId, mention: core.SymbolId, role: Role) error{}!bool {
    return role == .use and mention == symbol;
}

/// Collect the free variables of `term` into `out`, in first-mention order.
///
/// Globals, constructors and primitives are symbols too, and only a symbol in
/// `locals` is collected.
///
/// Preconditions:
/// - No binder in a walked term is in `locals`.
pub const Collector = struct {
    gpa: Allocator,
    /// The symbols to collect.
    locals: Locals,

    out: std.ArrayList(core.SymbolId) = .empty,

    pub fn deinit(self: *Collector) void {
        self.out.deinit(self.gpa);
    }

    pub const Locals = union(enum) {
        list: []const core.SymbolId,
        keys: *const std.AutoHashMapUnmanaged(core.SymbolId, u32),

        fn contains(self: Locals, symbol: core.SymbolId) bool {
            return switch (self) {
                .list => |list| std.mem.indexOfScalar(core.SymbolId, list, symbol) != null,
                .keys => |keys| keys.contains(symbol),
            };
        }
    };

    pub fn walk(self: *Collector, term: core.Term) Allocator.Error!void {
        _ = try anyMention(term, self, visit);
    }

    fn visit(self: *Collector, symbol: core.SymbolId, role: Role) Allocator.Error!bool {
        const local = self.locals.contains(symbol);
        switch (role) {
            .binder => std.debug.assert(!local),
            .use => if (local and std.mem.indexOfScalar(core.SymbolId, self.out.items, symbol) == null) {
                try self.out.append(self.gpa, symbol);
            },
        }
        return false;
    }
};
