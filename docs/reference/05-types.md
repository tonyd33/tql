# Types and classes

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

`->` is right-associative. `[τ]` is `List τ`. A type's free variables are
quantified at the outside of its signature; there is no `forall`.

## Kinds

```
(K-Var)   a : κ ∈ Δ
          ──────────
          Δ ⊢ a : κ

(K-Con)   T : κ ∈ Δ
          ──────────
          Δ ⊢ T : κ

(K-App)   Δ ⊢ τ1 : κ1 -> κ2     Δ ⊢ τ2 : κ1
          ─────────────────────────────────
          Δ ⊢ τ1 τ2 : κ2

(K-Fun)   Δ ⊢ τ1 : Type     Δ ⊢ τ2 : Type
          ───────────────────────────────
          Δ ⊢ τ1 -> τ2 : Type

(K-Rec)   Δ ⊢ ρ : Row
          ───────────────────
          Δ ⊢ Record ρ : Type
```

`Type` is the kind of types with values. `Row` is the kind of rows. Every
signature, field and annotation must have kind `Type`.

The kinds of a module's types, synonyms and classes are inferred one
dependency group at a time: the declarations that refer to each other
are kinded together, and a parameter nothing in its group constrains has
kind `Type`. A declaration's kind depends only on
its own group. A written kind signature on a parameter fixes it. Kinds are
not polymorphic.

| Constructor | Kind |
|---|---|
| `Int`, `String`, `Regex`, `Node`, `Kind`, `Bool`, `Ordering` | `Type` |
| `List`, `Maybe` | `Type -> Type` |
| `(->)`, `(,)` | `Type -> Type -> Type` |
| `Record` | `Row -> Type` |
| `Kleisli` | `(Type -> Type) -> Type -> Type -> Type` |

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

Labels are unordered, so `{a: Int, b: String}` and `{b: String, a: Int}`
are one type. A label repeated in one record type is an error. Two rows
are equal when they have the same labels with equal types and equal
tails.

A function over an open record accepts any record with at least its
fields:

```tql
name_of :: {name: String | r} -> String;
name_of x = x.name;
```

```
(T-Rec)    Γ ⊢ ei ⇒ τi       l1 ... ln distinct
           ─────────────────────────────────────────────
           Γ ⊢ {l1 = e1, ..., ln = en} ⇒ {l1: τ1, ..., ln: τn}

(T-Sel)    Γ ⊢ e ⇐ {l: τ | r}
           ──────────────────
           Γ ⊢ e.l ⇒ τ
```

### Classes over rows

`All C ρ` holds when every field of `ρ` has an instance of `C`. A record
has an instance of `Eq`, `Ord`, `ToJSON` or any other derivable class
when its row satisfies `All` of it ([E-Record](06-static-semantics.md#entailment)).
`All` may be written in a context:

```tql
same_name :: All Eq r => {name: String | r} -> {name: String | r} -> Bool;
same_name a b = a == b;
```

A record's fields are compared, and encoded, in label order.

A class whose parameter has kind `Row` is an error.

## Filters

```tql
type Filter = Kleisli List;
newtype Kleisli m a b = Kleisli (a -> m b);
```

A filter from `a` to `b` takes an `a` to a list of `b`s. `Filter` is a
synonym, so a filter is a `Kleisli List` arrow and has its instances. The
pipeline operator `|` composes filters, and `do` sequences them
([Pipelines](02-expressions.md#pipelines)).

## The standard types

| Type | Values |
|---|---|
| `Int` | 64-bit two's complement integers |
| `String` | well-formed UTF-8 text |
| `Regex` | compiled regular expressions; only literals |
| `Node` | nodes of a target file's syntax tree |
| `Kind` | node kinds of the target grammar |
| `Bool` | `False`, `True` |
| `Ordering` | `LT`, `EQ`, `GT` |
| `List a` | `Nil`, `Cons a (List a)` |
| `Maybe a` | `Nothing`, `Just a` |
| `(a1, ..., an)`, `()` | tuples, 2 ≤ n ≤ 255, and the unit |
| `Json` | `JNull`, `JBool Bool`, `JNumber Int`, `JString String`, `JArray [Json]`, `JObject [(String, Json)]` |

Their operations and instances are in [The standard library](11-library.md).
