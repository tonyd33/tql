//! Lowering and evaluation: checked Core to a running program.

const eval = @import("core_to_stg/eval.zig");
const free = @import("core_to_stg/free.zig");
const print = @import("core_to_stg/print.zig");
const stg = @import("core_to_stg/stg.zig");
const translate_mod = @import("core_to_stg/translate.zig");
const value = @import("core_to_stg/value.zig");

/// The term language the evaluator walks.
pub const Expr = stg.Expr;
pub const Atom = stg.Atom;
pub const Closure = stg.Closure;
pub const Constructed = stg.Constructed;
pub const Alternative = stg.Alternative;
pub const Allocation = stg.Allocation;
pub const Binding = stg.Binding;
pub const Definition = stg.Definition;
pub const Update = stg.Update;

/// A translated program and the arena its terms live in.
pub const Program = stg.Program;

/// Translates a checked program into the term language.
pub const translate = translate_mod.translate;

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
    refAllDecls(free);
    refAllDecls(print);
    refAllDecls(stg);
    refAllDecls(translate_mod);
    refAllDecls(value);
}
