# Patterns

## Grammar

```
pat     ::= apat
          | qcon apat+                       constructor or synonym, applied
          | pat ":" pat                      cons, infixr 5
          | pat "&" pat                      conjunction
          | var "@" apat                     as-pattern
          | "!" apat                         bang

apat    ::= var | "_" | literal
          | qcon
          | "(" pat ")"
          | "(" pat ("," pat)+ ")"   |   "(" ")"
          | "[" (pat ("," pat)*)? "]"
          | "(" exp "->" pat ")"             view
          | kind "{" (fpat ("," fpat)*)? "}"  node pattern
          | "{" fpat ("," fpat)* "}"         field pattern

fpat    ::= "#" field "=" pat
```

## The pattern kernel

Every pattern expands to these forms:

```
p ::= x            variable
    | _            wildcard
    | l            literal
    | K p1 ... pn  constructor, saturated
    | P p1 ... pn  pattern synonym, saturated
    | (e -> p)     view
    | p & q        conjunction
    | !p           bang
```

The surface forms expand as follows.

| Surface | Kernel |
|---|---|
| `x@p` | `x & p` |
| `[p1, ..., pn]` | `Cons p1 (... (Cons pn Nil))` |
| `p : q` | `Cons p q` |
| `(p1, ..., pn)`, `()` | the tuple constructor of arity n |
| `:k {}` | `(run (of_kind :k) -> [_])` |
| `:k { fs }` | `(run (of_kind :k) -> [{ fs }])` |
| `{ #f1 = p1, ..., #fn = pn }` | `(run #f1 -> [p1]) & ... & (run #fn -> [pn])` |

So `:k {}` matches a node of kind `k`, and `{ #f = p }` matches a node
with exactly one child in field `f`, which `p` matches.

A guard is the last item of its alternative's pattern:

```
p if c -> e   =   p & ((\_ -> c) -> True) -> e
```

## Meaning

`match p v` is one of `Ok θ`, a binding of `p`'s variables; `Fail`; or
`⊥`. Sequencing runs left to right and stops at the first `Fail` or `⊥`:

```
Fail  ⊕ m  =  Fail
⊥     ⊕ m  =  ⊥
Ok θ  ⊕ m  =  θ ∪ m          m runs with θ in scope
```

```
(M-Var)    match x v              =  Ok [x ↦ v]
(M-Wild)   match _ v              =  Ok []
(M-Con)    match (K p1 ... pn) v  =  ⊥                                    if v = ⊥
                                  =  match p1 v1 ⊕ ... ⊕ match pn vn      if v = K v1 ... vn
                                  =  Fail                                 otherwise
(M-New)    match (N p) v          =  match p (unN v)                      N a newtype constructor
(M-Lit)    match l v              =  if v == l then Ok [] else Fail
(M-Regex)  match r v              =  if v ~ r then Ok [] else Fail        r a regex literal
(M-View)   match (e -> p) v       =  match p (e v)
(M-And)    match (p & q) v        =  match p v ⊕ match q v
(M-Bang)   match !p v             =  seq v (match p v)
(M-Syn)    match (P p1 ... pn) v  =  matcher_P v (\x1 ... xn -> match p1 x1 ⊕ ... ⊕ match pn xn) Fail
```

A variable or wildcard forces nothing. A newtype constructor forces
nothing: `case loop of { N _ -> 1; }` is `1`. A view forces its value only
as far as its inner pattern does. In `match (e -> p)`, `e` is in scope of
the variables bound to its left in the same pattern.

The order of tests is part of the meaning, since a test that diverges
before another would have failed changes the result:

```tql
case (bot, True) of { (True, False) -> 1; (_, True) -> 2; _ -> 3; }
```

is `⊥`, since the first alternative forces `bot`. With the first two
alternatives swapped it is `2`.

## Typing

`Γ ⊢ p : τ ⇒ Δ` reads: in `Γ`, `p` matches values of type `τ` and binds
the variables in `Δ`. The checker checks a pattern against the type of
the value it matches.

```
(P-Var)    ─────────────────────
           Γ ⊢ x : τ ⇒ {x : τ}

(P-Wild)   ─────────────────
           Γ ⊢ _ : τ ⇒ {}

(P-Lit)    ty(l) = τ     Eq τ
           ────────────────────
           Γ ⊢ l : τ ⇒ {}

(P-Con)    K : ∀ā. τ1 -> ... -> τn -> T ā      Γ ⊢ pi : [ā := σ̄]τi ⇒ Δi
           ──────────────────────────────────────────────────────────
           Γ ⊢ K p1 ... pn : T σ̄ ⇒ Δ1 ∪ ... ∪ Δn

(P-View)   Γ, Δleft ⊢ e ⇒ τ -> τ'     Γ ⊢ p : τ' ⇒ Δ
           ─────────────────────────────────────────
           Γ ⊢ (e -> p) : τ ⇒ Δ

(P-And)    Γ ⊢ p : τ ⇒ Δp     Γ ⊢ q : τ ⇒ Δq     dom Δp ∩ dom Δq = ∅
           ─────────────────────────────────────────────────────────
           Γ ⊢ p & q : τ ⇒ Δp ∪ Δq

(P-Bang)   Γ ⊢ p : τ ⇒ Δ
           ──────────────────
           Γ ⊢ !p : τ ⇒ Δ
```

`ty(l)` is `Int` for an integer, `String` for a string and `Kind` for a
kind literal. A regex literal pattern matches a `String`. In P-Con the
`Δi` are pairwise disjoint. In P-View, `Δleft` is the variables bound to
the view's left in the same pattern.

A pattern synonym is typed by P-Con at its declared or inferred type
([Pattern synonyms](04-declarations.md#pattern-synonyms)).

A pattern that does not fit its scrutinee's type is reported at the
pattern: `:identifier` against a `Node` is an error at `:identifier`,
since a kind literal matches a `Kind`. Write `:identifier {}` to match a
node.

## Binders

A variable is bound at most once in one pattern, and at most once among
the patterns of one lambda, one clause and one `let` group. A repeat is an
error. The rule is checked on the expanded pattern, so `x & x` and `x@x`
are rejected.

A pattern variable shadows any binding of the same name outside the
pattern. `_` binds nothing and never counts as a repeat.

## Coverage

Coverage is a judgement over kernel patterns, independent of how matches
are compiled. A row of a match is useful when some value matches it and
no row above it. A match covers its scrutinee when a wildcard row added
at the end would not be useful. What a row covers is decided by these
rules:

- A constructor pattern covers its constructor. The constructors of a
  type cover it.
- A literal is a value with equality. A literal rules out other literals
  of its type, and only a variable or wildcard covers every value of a
  literal type.
- A regex literal decides nothing.
- A view, a guard and a pattern synonym are opaque: a row that uses one
  covers nothing beyond what the rest of the row covers.

Two judgements follow:

- A `case`, lambda, `let` pattern or definition head whose rows do not
  cover every value of the scrutinee is an error, `non-exhaustive`. A
  `case` with no alternatives is `non-exhaustive`.
- A row that no value reaches, given the rows above it, is an error,
  `redundant-alternative`.

A `do` bind is the one position where a pattern may fail at run time; it
falls through to `empty` ([Do](02-expressions.md#do)).

A list literal scrutinee is treated as any list: `case [1, 2] of { [a, b] -> a; }`
is non-exhaustive.
