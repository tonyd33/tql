//! What inlining a term costs.

const std = @import("std");
const core = @import("../core.zig");

/// Whether copying `t` costs nothing: a symbol, a number or a kind.
pub fn trivial(t: core.Term) bool {
    return switch (t.kind) {
        .symbol => true,
        .literal => |value| value == .number or value == .kind,
        else => false,
    };
}

/// What an argument at a call is known to be.
pub const Known = union(enum) {
    constructor: core.SymbolId,
    lambda,
};

pub const Measure = struct {
    size: u32 = 0,
    discount: u32 = 0,

    fn add(self: *Measure, other: Measure) void {
        self.size += other.size;
        self.discount += other.discount;
    }
};

/// The node count of `t`, and the nodes of it that the call's known
/// arguments remove: each `case p of` on a known constructor, less the
/// alternative it takes, and each application node headed by a known lambda.
///
/// `known[i]` is what the argument for `parameters[i]` is known to be.
pub fn measure(t: core.Term, parameters: []const core.SymbolId, known: []const ?Known) Measure {
    var result: Measure = .{ .size = 1 };
    switch (t.kind) {
        .symbol, .literal => {},
        .lambda => |lambda| result.add(measure(lambda.body, parameters, known)),
        .apply => |apply| {
            result.add(measure(apply.function, parameters, known));
            result.add(measure(apply.argument, parameters, known));
            if (knownAs(t.head(), parameters, known)) |k| {
                if (k == .lambda) result.discount += 1;
            }
        },
        .case => |case_term| {
            result.add(measure(case_term.scrutinee, parameters, known));
            const constructor = if (knownAs(case_term.scrutinee, parameters, known)) |k| switch (k) {
                .constructor => |id| id,
                .lambda => null,
            } else null;
            var taken: ?Measure = null;
            var discount: u32 = 0;
            for (case_term.alternatives) |alternative| {
                const body = measure(alternative.body, parameters, known);
                result.size += body.size;
                discount += body.discount;
                if (constructor == alternative.constructor) taken = body;
            }
            result.discount += if (taken) |body| result.size - body.size + body.discount else discount;
        },
        .let => |let| {
            result.add(measure(let.value, parameters, known));
            result.add(measure(let.body, parameters, known));
        },
        .letrec => |letrec| {
            for (letrec.bindings) |binding| result.add(measure(binding.value, parameters, known));
            result.add(measure(letrec.body, parameters, known));
        },
    }
    return result;
}

/// What `t` is known to be, when it is one of `parameters`.
fn knownAs(t: core.Term, parameters: []const core.SymbolId, known: []const ?Known) ?Known {
    if (t.kind != .symbol) return null;
    const i = std.mem.indexOfScalar(core.SymbolId, parameters, t.kind.symbol) orelse return null;
    return known[i];
}
