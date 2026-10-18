# Typed Core and the optimiser

After checking, a program is translated to Core: System F with data types
and casts. Every pass over Core keeps it well typed, and
a lint checks that after every pass.

## Terms

```
e ::= x | l
    | \(x : τ) -> e | e e
    | Λ(a : κ). e | e @τ
    | let x : τ = e in e
    | letrec { x : τ = e; ... } in e
    | case e of (b : τ) { K (x : τ)... -> e; ...; _ -> e }
    | e ▷ γ
    | join j (x : τ)... = e in e | jump j e...
```

A dictionary is a value of its class's dictionary type, and a constraint
`C τ` in a source type is the argument type `Dict_C τ` in Core.

## Typing

```
(C-Var)    x : τ ∈ Γ
           ──────────
           Γ ⊢ x : τ

(C-Abs)    Γ, x : τ1 ⊢ e : τ2
           ─────────────────────────────
           Γ ⊢ \(x : τ1) -> e : τ1 -> τ2

(C-App)    Γ ⊢ e1 : τ1 -> τ2     Γ ⊢ e2 : τ1
           ─────────────────────────────────
           Γ ⊢ e1 e2 : τ2

(C-TAbs)   Γ, a : κ ⊢ e : τ
           ─────────────────────────────
           Γ ⊢ Λ(a : κ). e : ∀(a : κ). τ

(C-TApp)   Γ ⊢ e : ∀(a : κ). τ     Γ ⊢ τ' : κ
           ──────────────────────────────────
           Γ ⊢ e @τ' : [a := τ']τ

(C-Let)    Γ ⊢ e1 : τ1     Γ, x : τ1 ⊢ e2 : τ2
           ───────────────────────────────────
           Γ ⊢ let x : τ1 = e1 in e2 : τ2

(C-Case)   Γ ⊢ e : T σ̄     Ki : ∀ā. τ̄i -> T ā     Γ, b : T σ̄, x̄i : [ā := σ̄]τ̄i ⊢ ei : τ
           ────────────────────────────────────────────────────────────────────
           Γ ⊢ case e of (b : T σ̄) { Ki x̄i -> ei } : τ

(C-Cast)   Γ ⊢ e : τ1     Γ ⊢ γ : τ1 ~R τ2
           ────────────────────────────────
           Γ ⊢ e ▷ γ : τ2

(C-Join)   Γ, x̄ : τ̄ ⊢ u : τ     Γ, j : τ̄ -> τ ⊢ e : τ
           ────────────────────────────────────────────
           Γ ⊢ join j (x̄ : τ̄) = u in e : τ
```

A `jump` to `j` appears only in tail position of `e`, and has the type of
the `join` that binds `j`.

`γ` is a coercion. A newtype `N ā = K τ` gives an axiom `N ā ~R τ`, and
coercions lift through type constructors by their parameters' roles. A
newtype's constructor and its match are casts, which cost nothing.

## The optimiser

The optimiser rewrites Core by equations that preserve its meaning, `⊥`
included, and do not repeat work.

It applies the calculus's own equations: beta reduction,
`(\x -> e) a = let x = a in e`, case of a known constructor, floating
a `let` out of a context it does not mention, inlining a binding used
once outside any lambda, and case of case through join points. It never
eta-expands a function that may be `⊥`.

Every other equation is a rewrite rule written in the library:

```tql
rule "children/of_kind" forall k. children | of_kind k = children_of_kind k;
```

Both sides of a rule are checked at one type, the right side with the
left side's constraints as givens. A rule must hold of the meanings of its
two sides for every value of its variables, `⊥` included. Only library
modules may declare rules.
