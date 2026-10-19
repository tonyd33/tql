# Types

## Notation

| Letter | Ranges over |
|---|---|
| `τ` | types |
| `ρ` | rows |
| `κ` | kinds |
| `a` | type variables |
| `r` | row variables |
| `T` | type constructors |
| `C` | classes |
| `l` | record labels |
| `Ψ` | kind environments |

## Grammar

```
sigtype ::= (context "=>")? type
context ::= constraint | "(" (constraint ("," constraint)*)? ")"
constraint ::= qcls atype | "All" qcls atype

type    ::= btype ("->" type)?
btype   ::= btype atype | atype
atype   ::= tyvar | qtycon
          | "(" type ")"
          | "(" type ("," type)+ ")"   |   "(" ")"
          | "[" type "]"
          | "(" "->" ")"   |   "(" ","+ ")"
          | "{" (label ":" type ("," label ":" type)*)? ("|" tyvar)? "}"

kind    ::= "Type" | "Row" | kind "->" kind | "(" kind ")"
```

`->` is right-associative, and `[τ]` is `List τ`. A type's free
variables are quantified at the outside of its signature. There is no
`forall`.

A constraint's type is a type variable, possibly applied to types. A
constraint on any other type is an error, `invalid-class`.

## Kinds

`Ψ ⊢ τ : κ` reads: in `Ψ`, `τ` has kind `κ`. The rules are named `K-`.

```
(K-Var)   a : κ ∈ Ψ
          ──────────
          Ψ ⊢ a : κ

(K-Con)   T : κ ∈ Ψ
          ──────────
          Ψ ⊢ T : κ

(K-App)   Ψ ⊢ τ1 : κ1 -> κ2     Ψ ⊢ τ2 : κ1
          ─────────────────────────────────
          Ψ ⊢ τ1 τ2 : κ2

(K-Fun)   Ψ ⊢ τ1 : Type     Ψ ⊢ τ2 : Type
          ───────────────────────────────
          Ψ ⊢ τ1 -> τ2 : Type

(K-Rec)   Ψ ⊢ ρ : Row
          ───────────────────
          Ψ ⊢ Record ρ : Type
```

`Type` is the kind of types with values, and `Row` the kind of rows.
Every signature, field and annotation must have kind `Type`. A type of
the wrong kind is an error, `kind-mismatch`.

The built-in type constructors have these kinds:

| Constructor | Kind |
|---|---|
| `Int`, `String`, `Regex`, `Node`, `Kind` | `Type` |
| `(->)` | `Type -> Type -> Type` |
| the tuple constructor of n components, `()` when n = 0 | `Type -> ... -> Type`, of n arguments |
| `Record` | `Row -> Type` |

Every other type constructor is declared, in the library or the program,
and its kind is inferred from its declaration. The kinds of a module's
types, synonyms and classes are inferred one dependency group at a time.
Declarations that refer to each other are kinded together, and a
declaration's kind depends only on its own dependency group. A parameter
nothing in its dependency group constrains has kind `Type`, and a written kind signature on a
parameter fixes its kind. Kinds are not polymorphic.

## Records and rows

A row is a set of labels, each with a type, and possibly a tail: a row
variable standing for further labels.

```
ρ ::= ()  |  (l : τ | ρ)  |  r
```

This notation is the reference's own. A program writes a row only inside
record braces, and a record type is `Record` at a row:

```
{l1: τ1, ..., ln: τn}          =   Record (l1 : τ1 | ... | (ln : τn | ()))
{l1: τ1, ..., ln: τn | r}      =   Record (l1 : τ1 | ... | (ln : τn | r))
```

Two rows are equal when they have the same labels with equal types and
equal tails, in any order: `{a: Int, b: String}` and
`{b: String, a: Int}` are one type. A label repeated in one record type
is an error, `duplicate-definition`.

A function over an open record accepts any record with at least its
fields:

```tql
name_of :: {name: String | r} -> String;
name_of x = x.name;
```

A row has each label at most once. A row variable lacks every label of
every row it is the tail of: in a signature, with synonyms expanded, or in
a type inference builds. A datatype's parameter lacks what its fields need
it to lack, and so does the parameter's argument wherever the datatype is
applied: with `data W r = W {x: Int | r};`, `r` lacks `x` in
`h :: W r -> Int`. A row variable is never bound to a row with a label it
lacks:

```tql
f :: {a: Int | r} -> {b: Int | r} -> Int;
f x y = x.a + y.b;
```

`r` lacks `a` and `b`, so `f {a = 1, b = "s"}` is an error,
`type-mismatch`.

The record constants of the [translation](02-expressions.md#record) and
of [derived instances](05-declarations.md#deriving) have these types:

```
record_{l1 ... ln}  ::  a1 -> ... -> an -> {l1: a1, ..., ln: an}
select_l            ::  {l: a | r} -> a
extend_l            ::  a -> Record r -> {l: a | r}
restrict_l          ::  {l: a | r} -> Record r
```

### Classes over rows

`All C ρ` holds when every field of `ρ` has an instance of `C`. `Prim`
declares `All`; its first argument is a class and its second a row. A
constraint naming two classes names `All` first, or is an error,
`invalid-class`. A record has an instance of `Eq`, `Ord`, `ToJson` or any
other derivable class when its row satisfies `All` of it
([E-Record](06-static-semantics.md#entailment)). A record's fields are
compared and encoded in label order. `All` may be written in a context:

```tql
same_name :: All Eq r => {name: String | r} -> {name: String | r} -> Bool;
same_name a b = a == b;
```

A class whose parameter has kind `Row` is an error, `invalid-class`.
