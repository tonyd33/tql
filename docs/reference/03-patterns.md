# Patterns

## Notation

| Letter | Ranges over |
|---|---|
| `p`, `q` | patterns |
| `fs` | sequences of field patterns |
| `x` | variables |
| `e`, `c` | expressions |
| `v` | values |
| `lit` | literals |
| `K` | constructors |
| `N` | newtype constructors |
| `P` | pattern synonyms |
| `k` | node kinds |
| `f` | fields |
| `m` | results of matches |
| `θ` | bindings of variables to values |
| `τ`, `σ` | types |
| `a` | type variables |
| `T` | type constructors |
| `Γ` | type environments |
| `Δ` | the variables a pattern binds, with their types |

A bar marks a sequence: `ā` is `a1 ... an`.

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
          | kindlit "{" (fpat ("," fpat)*)? "}"  node pattern
          | "{" fpat ("," fpat)* "}"         field pattern

fpat    ::= "#" field "=" pat
```

## The pattern kernel

Every pattern expands to these forms:

```
p ::= x            variable
    | _            wildcard
    | lit          literal
    | K p1 ... pn  constructor, saturated
    | P p1 ... pn  pattern synonym, saturated
    | (e -> p)     view
    | p & q        conjunction
    | !p           bang
```

The surface forms expand as follows. A library name in an expansion
(`Cons`, `run`, `of_kind`) is the library's, whatever the program's own
scope holds.

| Surface | Kernel |
|---|---|
| `x@p` | `x & p` |
| `[p1, ..., pn]` | `Cons p1 (... (Cons pn Nil))` |
| `p : q` | `Cons p q` |
| `(p1, ..., pn)`, `()` | the tuple constructor of arity n |
| `r"..."`, a regex literal | `((\s -> (~) s r"...") -> True)` |
| `:k {}` | `(run (of_kind :k) -> Cons _ Nil)` |
| `:k { fs }` | `(run (of_kind :k) -> Cons { fs } Nil)` |
| `{ #f1 = p1, ..., #fn = pn }` | `(field_f1 -> Cons p1 Nil) & ... & (field_fn -> Cons pn Nil)` |

So `:k {}` matches a node of kind `k`, and `{ #f = p }` matches a node
with exactly one child in field `f`, which `p` matches.

A guard is the last item of its alternative's pattern:

```
p if c -> e   =   p & ((\_ -> c) -> True) -> e
```

## Meaning

`match p v` is one of `Ok θ`, a binding of `p`'s variables; `Fail`; or
`⊥`. The rules are named `M-`. Sequencing runs left to right and stops at the first `Fail` or `⊥`:

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
(M-Lit)    match lit v            =  if v == lit then Ok [] else Fail
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

`Γ ⊢ p : τ ⊣ Δ` reads: in `Γ`, `p` matches values of type `τ` and binds
the variables in `Δ`. The rules are named `P-`. The checker checks a pattern against the type of
the value it matches.

```
(P-Var)    ─────────────────────
           Γ ⊢ x : τ ⊣ {x : τ}

(P-Wild)   ─────────────────
           Γ ⊢ _ : τ ⊣ {}

(P-Lit)    ty(lit) = τ     Eq τ
           ──────────────────────
           Γ ⊢ lit : τ ⊣ {}

(P-Con)    K : ∀ā. τ1 -> ... -> τn -> T ā      Γ ⊢ pi : [ā := σ̄]τi ⊣ Δi
           ──────────────────────────────────────────────────────────
           Γ ⊢ K p1 ... pn : T σ̄ ⊣ Δ1 ∪ ... ∪ Δn

(P-View)   Γ, Δleft ⊢ e ⇒ τ -> τ'     Γ ⊢ p : τ' ⊣ Δ
           ─────────────────────────────────────────
           Γ ⊢ (e -> p) : τ ⊣ Δ

(P-And)    Γ ⊢ p : τ ⊣ Δp     Γ ⊢ q : τ ⊣ Δq     dom Δp ∩ dom Δq = ∅
           ─────────────────────────────────────────────────────────
           Γ ⊢ p & q : τ ⊣ Δp ∪ Δq

(P-Bang)   Γ ⊢ p : τ ⊣ Δ
           ──────────────────
           Γ ⊢ !p : τ ⊣ Δ
```

`ty(lit)` is in [Expressions](06-static-semantics.md#expressions). In P-Con the
`Δi` are pairwise disjoint. In P-View, `Δleft` is the variables bound to
the view's left in the same pattern.

A pattern synonym is typed by P-Con at its declared or inferred type
([Pattern synonym](05-declarations.md#pattern-synonym)).

A pattern that does not fit its scrutinee's type is reported at the
pattern: `:identifier` against a `Node` is an error, `type-mismatch`, at
`:identifier`,
since a kind literal matches a `Kind`. Write `:identifier {}` to match a
node.

## Binders

A variable is bound at most once in one pattern, and at most once among
the patterns of one lambda, one clause and one `let` group. A repeat is an
error, `duplicate-definition`. The rule is checked on the expanded pattern, so `x & x` and `x@x`
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
- A view, a guard and a pattern synonym are opaque: a row that uses one
  covers nothing beyond what the rest of the row covers.

Two judgements follow:

- A `case`, lambda, `let` pattern or definition head whose rows do not
  cover every value of the scrutinee is an error, `non-exhaustive`. A
  `case` with no alternatives is `non-exhaustive`.
- A row that no value reaches, given the rows above it, is an error,
  `redundant-alternative`.

A `do` bind is the one position where a refutable pattern is legal: its
translation adds an alternative that yields `empty`
([Do expression](02-expressions.md#do-expression)).

A list literal scrutinee is treated as any list: `case [1, 2] of { [a, b] -> a; }`
is non-exhaustive.
