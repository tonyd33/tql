# Typed Core and the optimiser

After checking, match compilation, operator lowering and elaboration
translate a program to Core: System F with datatypes and casts. Every pass over Core keeps it well typed, and
a lint checks that after every pass.

## Terms

```
e ::= x | lit
    | \(x : τ) -> e | e e
    | Λ(a : κ). e | e @τ
    | let x : τ = e in e
    | letrec { x : τ = e; ... } in e
    | case e of (b : τ) { K (x : τ)... -> e; ...; _ -> e }
    | e ▷ γ
    | join j (x : τ)... = e in e | jump j e...
```

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

`γ` is a coercion. A newtype `T ā = K τ` gives an axiom `T ā ~R τ`, and
coercions lift through type constructors by their parameters' roles. A
newtype's constructor and its match are casts, which cost nothing.

## Elaboration

Elaboration makes evidence explicit. A constraint `C τ` in a source type
is the argument type `Dict_C τ` in Core, and a dictionary is a value of
it.

A class is a dictionary type and selectors:

```
class (S1 a, ..., Sk a) => C a where { m1 :: τ1; ...; mn :: τn; }

data Dict_C a = Dict_C (Dict_S1 a) ... (Dict_Sk a) τ1 ... τn
mi       :: ∀a. Dict_C a -> τi
super_Sj :: ∀a. Dict_C a -> Dict_Sj a
```

A method type that quantifies further variables gives a polymorphic
field.

An instance is a dictionary, a function of the context's dictionaries:

```
instance (C1 a1, ..., Cj aj) => C (T ā) where { ... }

inst_C_T :: ∀ā. Dict_C1 a1 -> ... -> Dict_Cj aj -> Dict_C (T ā)
```

Its superclass fields are the evidence of the superclass wanteds
([Instance](05-declarations.md#instance)).

Each class wanted has an evidence variable. Solving it binds the variable
in the scope that solved it:

```
let d : Dict_C (T τ̄) = inst_C_T d1 ... dj in e
```

A wanted for a constraint already solved in its scope, or an enclosing
one, shares that evidence.

A binding group takes its dictionaries once. Its members are monomorphic
copies in a `letrec` inside the abstraction, and a recursive use reaches
the copy, passing no dictionary:

```
f = \(d : Dict_C a) -> let ev : τ = ... in letrec { f' : τ' = ... f' ...; } in f'
```

A binding group of several members builds `\k -> k f1' ... fn'`, and each
member applies it to the selector of its own copy.

## The optimiser

The optimiser rewrites Core by equations that preserve its meaning, `⊥`
included, and do not repeat work.

It applies the calculus's own equations: beta reduction,
`(\x -> e) a = let x = a in e`, case of a known constructor, floating
a `let` out of a context it does not mention, inlining a binding used
once outside any lambda, and case of case through join points. It never
eta-expands a function that may be `⊥`.

Every other equation is a rewrite rule written in the library:

```
rule ::= "rule" string ("forall" var+ ".")? exp "=" exp
```

```tql
rule "navigate/of_kind" forall a k.
  Kleisli (navigate a Any) | of_kind k = Kleisli (navigate a $ OfKind k);
```

A rule's variables are the names its `forall` binds, quantified over
the rule as a signature's are. Both sides of a rule are checked at one
type, the right side with the left side's constraints as givens. A rule must hold of the meanings of its
two sides for every value of its variables, `⊥` included. Only library
modules may declare rules; a rule elsewhere is an error, `invalid-rule`.
