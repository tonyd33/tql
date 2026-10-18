# Static semantics

The checker is bidirectional and constraint-based, over rank-1 types. It
reads each binding, generates constraints, and solves them.

## Judgements

```
Γ ⊢ e ⇒ τ  ⇝ W      e has type τ, provided W holds        (inference)
Γ ⊢ e ⇐ τ  ⇝ W      e checks against τ, provided W holds  (checking)
Q ⊩ π  ⇝ d          the givens Q entail π, with evidence d
```

`Γ` maps variables to type schemes `∀ā. Q => τ`. Wanted constraints are

```
W ::= ε  |  W ∧ W  |  τ1 ~ τ2  |  π  |  ∀ā. (Q ⊃ W)
```

The last form is an implication: under fresh rigid variables `ā` and
givens `Q`, `W` holds. Each implication has a level, one deeper than the
scope it is in. A rigid variable may not escape its implication, and a
type variable from an outer level may not be unified with it.

## Expressions

```
(T-Var)    x : ∀ā. Q => τ ∈ Γ      β̄ fresh
           ───────────────────────────────────────
           Γ ⊢ x ⇒ [ā := β̄]τ  ⇝  [ā := β̄]Q

(T-Lit)    ───────────────────────
           Γ ⊢ lit ⇒ ty(lit)  ⇝  ε

(T-Abs⇐)   Γ, x : τ1 ⊢ e ⇐ τ2  ⇝  W
           ────────────────────────────
           Γ ⊢ \x -> e ⇐ τ1 -> τ2  ⇝  W

(T-Abs⇒)   α fresh      Γ, x : α ⊢ e ⇒ τ  ⇝  W
           ─────────────────────────────────────
           Γ ⊢ \x -> e ⇒ α -> τ  ⇝  W

(T-App)    Γ ⊢ e1 ⇒ τ1  ⇝  W1      α, β fresh      Γ ⊢ e2 ⇐ α  ⇝  W2
           ─────────────────────────────────────────────────────────
           Γ ⊢ e1 e2 ⇒ β  ⇝  W1 ∧ τ1 ~ (α -> β) ∧ W2

(T-App⇐)   Γ ⊢ f ⇒ τ0  ⇝  W0      α1 ... αn fresh      Γ ⊢ ei ⇐ αi  ⇝  Wi
           ─────────────────────────────────────────────────────────────────
           Γ ⊢ f e1 ... en ⇐ τ  ⇝  W0 ∧ τ0 ~ (α1 -> ... -> αn -> τ) ∧ W1 ∧ ... ∧ Wn

(T-Sub)    Γ ⊢ e ⇒ τ'  ⇝  W
           ───────────────────────────
           Γ ⊢ e ⇐ τ  ⇝  W ∧ τ' ~ τ

(T-Case)   Γ ⊢ e ⇒ τs  ⇝  W0
           Γ ⊢ pi : τs ⊣ Δi      Γ, Δi ⊢ gi ⇐ Bool  ⇝  Gi      Γ, Δi ⊢ ei ⇐ τ  ⇝  Wi
           ───────────────────────────────────────────────────────────────────────
           Γ ⊢ case e of { pi if gi -> ei; } ⇐ τ  ⇝  W0 ∧ G1 ∧ W1 ∧ ... ∧ Gn ∧ Wn
```

`ty(lit)` is `Int` for an integer, `String` for a string, `Regex` for a
regex and `Kind` for a kind literal. Literals are not overloaded. Every other expression form is typed by its translation.

In T-App⇐, `f` is not an application, and `n ≥ 1`. Since wanteds arise
in the order a conclusion writes them ([Solving](#solving)), `f`'s result
is unified with `τ` before any argument is checked.

### Annotations

```
(T-Ann)    ā fresh rigid      β̄ fresh      Γ ⊢ e ⇐ τ  ⇝  W
           ──────────────────────────────────────────────────────
           Γ ⊢ (e :: ∀ā. Q => τ) ⇒ [ā := β̄]τ  ⇝  ∀ā. (Q ⊃ W) ∧ [ā := β̄]Q
```

## Bindings

```
(T-Sig)    f : σ ∈ Γ      σ = ∀ā. Q => τ      ā fresh rigid
           Γ ⊢ e ⇐ τ  ⇝  W
           ──────────────────────────────────────────
           Γ ⊢ (f :: σ; f = e;)  ⊣  f : σ  ⇝  ∀ā. (Q ⊃ W)

(T-Group)  x1 ... xn one binding group, none signed      ᾱ fresh, one level deeper
           Γ, x1 : α1, ..., xn : αn ⊢ ei ⇒ τi  ⇝  Wi      αi ~ τi
           (σ1, ..., σn; W) = Gen(Γ, τ1 ... τn, W1 ∧ ... ∧ Wn)
           ─────────────────────────────────────────────────
           Γ ⊢ (x1 = e1; ...; xn = en;)  ⊣  x1 : σ1, ..., xn : σn  ⇝  W

(T-Let⇐)   Γ ⊢ bs ⊣ Γ'  ⇝  W1      Γ, Γ' ⊢ e ⇐ τ  ⇝  W2
           ─────────────────────────────────────────────
           Γ ⊢ let { bs } in e ⇐ τ  ⇝  W1 ∧ W2

(T-Let⇒)   Γ ⊢ bs ⊣ Γ'  ⇝  W1      Γ, Γ' ⊢ e ⇒ τ  ⇝  W2
           ─────────────────────────────────────────────
           Γ ⊢ let { bs } in e ⇒ τ  ⇝  W1 ∧ W2
```

`Γ ⊢ bs ⊣ Γ' ⇝ W` types the [binding groups](05-declarations.md#binding-group)
of `bs` in dependency order, each by T-Sig or T-Group. `Γ'` holds the
schemes they give, and `W` the wanteds they leave to the enclosing
scope.

`Gen` quantifies the type variables of the binding group's level that no outer
type mentions, with the context [Generalisation](#generalisation) gives
it, and returns the wanteds that float out, `W`. The members of a binding
group share one context.

`Gen` quantifies only what [Generalisation](05-declarations.md#generalisation)
allows. A variable it leaves unquantified moves to the outer level, as a
variable of the environment, and the constraints on it float to the
enclosing scope.

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
`C derivable` is as [Deriving](05-declarations.md#deriving) defines it,
and `derived_C` builds `C`'s methods over the fields from it, as `C`'s
deriver does over a constructor's.

A program has at most one instance per class and head
([Instance](05-declarations.md#instance)), so E-Inst is
syntax-directed: at most one instance applies to a constraint, and the
solver never backtracks.

## Solving

Wanteds arise in the order a rule's conclusion writes them. An equality
`τ1 ~ τ2` is solved by unification as it arises. Class
wanteds are solved at each binding group's generalisation and once at
the top of the program.

A class wanted is solved once, against the givens in scope, then their
superclasses, then the instances. A wanted on a type variable, or on a
type whose head is a variable, is not reduced by an instance: it is
solved from the givens, or kept as a residual. Any other wanted is
reduced by E-Inst until its residuals are of that form.

### Generalisation

`Gen` reduces the binding group's wanteds and takes as context the residuals on
the variables it quantifies, without those another's superclass entails.
It solves the wanteds with that context as givens.

A wanted, or a residual of one, that mentions no quantified variable
floats to the enclosing scope, so `Eq Int` is solved once, at the top. A
residual on a variable neither quantified nor in the environment is an
error at once, `ambiguous-constraint`.

What reaches the top is solved there, with no givens. A residual still
on a variable is `ambiguous-constraint`.

### Evidence

Solving a class wanted binds its evidence. Where evidence is bound, when
it is shared, and how a binding group takes its dictionaries is in
[Elaboration](12-core.md#elaboration).

## Ambiguity

A scheme `∀ā. Q => τ` is ambiguous when a variable of `Q` does not occur in
`τ`, with synonyms expanded. An ambiguous scheme is an error at its
binding, `ambiguous-constraint`, whether it was inferred or written.

There is no defaulting.

## Errors

A wanted that no rule can solve is insoluble. A class wanted that an
instance lookup refutes is `unsatisfied-constraint`, and an equality that
unification cannot solve, between distinct constructors or a variable and
a type containing it, is `type-mismatch`, each at the expression it came
from.

Under a signature, a type that does not fit a rigid variable is
`type-mismatch` at the expression, naming the variable and its signature.
A class wanted on rigid variables that the signature's context does not
entail is `signature-mismatch` at the expression that raised it.

Checking continues past an insoluble wanted. Every insoluble wanted of a
program is reported, except one that follows from another. An error
poisons the types it is about, and what their variables are unified with.
A use of an undefined name, or of a binding whose type is poisoned, has a
poisoned type. An error about a poisoned type is not reported.
