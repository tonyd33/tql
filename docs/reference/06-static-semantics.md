# Static semantics

The checker is bidirectional and constraint-based, over rank-1 types. It
reads each binding, generates constraints, and solves them.

## Judgements

```
Γ ⊢ e ⇒ τ  ⇝ W      e has type τ, provided W holds        (inference)
Γ ⊢ e ⇐ τ  ⇝ W      e checks against τ, provided W holds  (checking)
Q ⊩ π  ⇝ d          the givens Q entail π, with evidence d
```

`Γ` maps variables to type schemes `∀ā. Q ⇒ τ`. Wanted constraints are

```
W ::= ε  |  W ∧ W  |  τ1 ~ τ2  |  π  |  ∀ā. (Q ⊃ W)
```

The last form is an implication: under fresh rigid variables `ā` and
givens `Q`, `W` holds. Each implication has a level, one deeper than the
scope it is in. A rigid variable may not escape its implication, and a
type variable from an outer level may not be unified with it.

## Expressions

```
(T-Var)    x : ∀ā. Q ⇒ τ ∈ Γ      β̄ fresh
           ───────────────────────────────────────
           Γ ⊢ x ⇒ [ā := β̄]τ  ⇝  [ā := β̄]Q

(T-Lit)    ───────────────────
           Γ ⊢ l ⇒ ty(l)  ⇝  ε

(T-Abs⇐)   Γ, x : τ1 ⊢ e ⇐ τ2  ⇝  W
           ────────────────────────────
           Γ ⊢ \x -> e ⇐ τ1 -> τ2  ⇝  W

(T-Abs⇒)   α fresh      Γ, x : α ⊢ e ⇒ τ  ⇝  W
           ─────────────────────────────────────
           Γ ⊢ \x -> e ⇒ α -> τ  ⇝  W

(T-App)    Γ ⊢ e1 ⇒ τ1  ⇝  W1      α, β fresh      Γ ⊢ e2 ⇐ α  ⇝  W2
           ─────────────────────────────────────────────────────────
           Γ ⊢ e1 e2 ⇒ β  ⇝  W1 ∧ τ1 ~ (α -> β) ∧ W2

(T-Sub)    Γ ⊢ e ⇒ τ'  ⇝  W
           ───────────────────────────
           Γ ⊢ e ⇐ τ  ⇝  W ∧ τ' ~ τ

(T-Case)   Γ ⊢ e ⇒ τs  ⇝  W0
           Γ ⊢ pi : τs ⇒ Δi      Γ, Δi ⊢ gi ⇐ Bool  ⇝  Gi      Γ, Δi ⊢ ei ⇐ τ  ⇝  Wi
           ───────────────────────────────────────────────────────────────────────
           Γ ⊢ case e of { pi if gi -> ei } ⇐ τ  ⇝  W0 ∧ G1 ∧ W1 ∧ ... ∧ Gn ∧ Wn
```

`ty(l)` is `Int`, `String`, `Regex` or `Kind`. Literals are not overloaded.
Every other expression form is typed by its translation.

### Annotations

```
(T-Ann)    ā fresh rigid      Γ ⊢ e ⇐ τ  ⇝  W
           ──────────────────────────────────────────────────────
           Γ ⊢ (e :: ∀ā. Q ⇒ τ) ⇒ [ā := β̄]τ  ⇝  ∀ā. (Q ⊃ W) ∧ [ā := β̄]Q
```

with `β̄` fresh.

## Bindings

```
(T-Sig)    f : σ ∈ Γ      σ = ∀ā. Q ⇒ τ      ā fresh rigid
           Γ ⊢ e ⇐ τ  ⇝  W
           ──────────────────────────────
           Γ ⊢ (f :: σ; f = e)  ⇝  ∀ā. (Q ⊃ W)

(T-Group)  x1 ... xn one binding group, none signed      ᾱ fresh, one level deeper
           Γ, x1 : α1, ..., xn : αn ⊢ ei ⇒ τi  ⇝  Wi      αi ~ τi
           (σ1, ..., σn) = Gen(Γ, τ1 ... τn, W1 ∧ ... ∧ Wn)
           ─────────────────────────────────────────────────
           Γ ⊢ (x1 = e1; ...; xn = en)  ⇒  x1 : σ1, ..., xn : σn
```

`Gen` solves the group's wanteds as far as they can be solved, then
quantifies the type variables of the group's level that no outer type
mentions, together with the residual constraints over them. The members
of a group share one context. The [generalisation](04-declarations.md#generalisation)
rules restrict which variables `Gen` may quantify: for a top-level
binding without parameters or signature, and for a local binding that
mentions an enclosing variable, it quantifies none of the constrained
ones, and their constraints float to the enclosing scope.

## Entailment

```
(E-Given)    (d : π) ∈ Q
             ────────────
             Q ⊩ π  ⇝  d

(E-Super)    Q ⊩ C τ  ⇝  d      class (..., S a, ...) => C a
             ─────────────────────────────────────────────
             Q ⊩ S τ  ⇝  super_S d

(E-Inst)     instance (C1 a1, ..., Cj aj) => C (T ā)      Q ⊩ Ci [ā := τ̄]ai  ⇝  di
             ─────────────────────────────────────────────────────────────────
             Q ⊩ C (T τ̄)  ⇝  inst_C_T d1 ... dj

(E-AllNil)   ────────────────
             Q ⊩ All C ()  ⇝  ⟨⟩

(E-AllCons)  Q ⊩ C τ  ⇝  d1      Q ⊩ All C ρ  ⇝  d2
             ───────────────────────────────────────
             Q ⊩ All C (l : τ | ρ)  ⇝  ⟨d1, d2⟩

(E-Record)   C derivable      Q ⊩ All C ρ  ⇝  d
             ──────────────────────────────────
             Q ⊩ C (Record ρ)  ⇝  derived_C d
```

The evidence of `All C ρ` lists one dictionary per field, in label order.
`derived_C` builds `C`'s methods over the fields from it.

Instances are unique per class and head, so E-Inst is syntax-directed:
at most one instance applies to a constraint, and the solver never
backtracks.

## Solving

Each wanted is solved once, against the givens in scope, then their
superclasses, then the instances. Solving it produces its evidence. The
solver runs at each binding group's generalisation and once at the top
of the program.

A wanted on a type variable, or on a type whose head is a variable, is
not reduced by an instance: it is solved from the givens, or kept for
generalisation. Any other wanted is reduced by E-Inst until what is left
is of that form. A wanted that no rule solves is an error,
`unsatisfied-constraint`, reported at the expression it came from.

Every insoluble wanted of a program is reported, except those in a
binding whose type depended on a binding that already failed.

## Ambiguity

A scheme `∀ā. Q ⇒ τ` is ambiguous when a variable of `Q` does not occur in
`τ`, with synonyms expanded. An ambiguous scheme is an error at its
binding, `ambiguous-constraint`, whether it was inferred or written.

There is no defaulting. A program states the type it means.
