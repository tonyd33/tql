//! Which rewrites the simplifier applies.

/// Every rewrite can be switched off alone, to measure what it buys.
pub const Options = struct {
    /// `(\x -> b) a` binds `x` to `a`.
    beta: bool = true,
    /// `E[let x = e in f]` is `let x = e in E[f]`, for an application or
    /// `case` frame `E`.
    let_from_head: bool = true,
    /// A binding nothing uses is dropped, and so is a recursive group nothing
    /// live mentions and a global `main` does not reach.
    dead_bindings: bool = true,
    /// A dictionary that every call of a function passes the same is
    /// substituted into its body, and the parameter dropped.
    dictionary_arguments: bool = true,
    /// A binding used once moves to its occurrence.
    pre_inline: bool = true,
    /// A binding to a trivial value, local or global, is substituted at every
    /// occurrence.
    post_inline: bool = true,
    /// A `let` or `letrec` binder only ever called, with one number of
    /// arguments, in tail position becomes a join point.
    contification: bool = true,
    /// A `case` of a known constructor takes its alternative.
    case_of_known_constructor: bool = true,
    /// A saturated call to a function small enough, or marked to always
    /// inline, is replaced by a copy of its body.
    call_site_inline: bool = true,
    laws: bool = true,
    /// The largest unfolding, less its discounts, a call inlines without the
    /// always-inline mark.
    inline_threshold: u32 = 12,
    /// Iterations per simplifier run before it stops short of a fixpoint.
    max_iterations: u32 = 4,
    /// Rounds of dictionary substitution, each followed by a simplifier run,
    /// per phase.
    max_substitution_rounds: u32 = 4,
};
