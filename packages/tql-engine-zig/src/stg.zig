//! The STG term language, and the machine that runs it.

const eval = @import("stg/eval.zig");
const print = @import("stg/print.zig");
const terms = @import("stg/terms.zig");
const value = @import("stg/value.zig");

/// The term language the evaluator walks.
pub const Expr = terms.Expr;
pub const Atom = terms.Atom;
pub const Literal = terms.Literal;
pub const Regex = terms.Regex;
pub const Local = terms.Local;
pub const Closure = terms.Closure;
pub const Constructed = terms.Constructed;
pub const Alternative = terms.Alternative;
pub const Allocation = terms.Allocation;
pub const Binding = terms.Binding;
pub const Definition = terms.Definition;
pub const Update = terms.Update;

/// A translated program and the arena its terms live in.
pub const Program = terms.Program;

/// Renders translated terms.
pub const Printer = print.Printer;

/// The evaluator.
pub const Machine = eval.Machine;

/// Allocation counters by call site. Profiling only.
pub const Site = eval.Site;
pub const site_counts = &eval.site_counts;
pub const site_bytes = &eval.site_bytes;
pub const count_allocations = eval.count_allocations;

/// Runtime values, and the thunks that produce them.
pub const Value = value.Value;
pub const Thunk = value.Thunk;
pub const Node = value.Node;
pub const Range = value.Range;
pub const Point = value.Point;

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(eval);
    refAllDecls(print);
    refAllDecls(terms);
    refAllDecls(value);
}
