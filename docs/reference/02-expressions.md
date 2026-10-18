# Expressions

## Grammar

```
exp     ::= lexp (qop lexp)*

lexp    ::= "\" apat+ "->" exp
          | "let" binds "in" exp
          | "if" exp "then" exp "else" exp
          | "case" exp "of" "{" (alt ";")* "}"
          | "do" "{" (stmt ";")* exp ";"? "}"
          | fexp

fexp    ::= fexp arg | aexp
arg     ::= aexp | "\" ... | "let" ... | "if" ... | "case" ... | "do" ...

aexp    ::= qvar | qcon | literal
          | "(" exp ")"
          | "(" exp ("," exp)+ ")"   |   "(" ")"
          | "[" (exp ("," exp)*)? "]"
          | "{" (label "=" exp ("," label "=" exp)*)? "}"
          | "(" exp "::" sigtype ")"
          | "(" qop ")"   |   "(" lexp qop ")"   |   "(" qop lexp ")"
          | "(" ("." label)+ ")"
          | aexp "." label
          | aexp "#" field
          | "#" field

alt     ::= pat ("if" exp)? "->" exp
stmt    ::= exp | pat "<-" exp | "let" binds
binds   ::= "{" (bind ";")* "}" | bind (";" bind)*
```

A lambda, `let`, `if` or `case` extends as far to the right as it can. Any
of them, and `do`, may be a function argument without brackets:
`map \x -> x + 1`, `f do { ... }`.

Application is left-associative and binds tighter than every operator.
Field selection `x.f` and field navigation `n#f` bind tighter than
application, so `range n.start` is `range (n.start)`.

## Variables, constructors and literals

A variable or constructor denotes its binding in scope
([Name resolution](07-modules.md#name-resolution)). A literal denotes its
value at its type ([Literals](01-lexical.md#literals)).

## Operators

An operator application is the application of the operator's binding:

```
e1 op e2     =   (op) e1 e2
e1 `f` e2    =   f e1 e2
```

`f` in backticks is a variable, a qualified name or a constructor.

A chain `e1 op1 e2 op2 ... en` is grouped by the operators' fixities:

- The tighter operator groups first.
- At one level, left-associative operators group to the left and
  right-associative ones to the right.
- Two operators at one level that are non-associative, or whose
  associativities differ, are an error. `a < b < c` and `a && b <|> c`
  are errors; bracket one side.

The operators of the standard library, tightest first:

| Operator | Fixity | Binding |
|---|---|---|
| `.` | `infixr 9` | `Control.Category`: composition |
| `` `f` `` | `infixl 9` unless `f` declares one | `f` |
| `*` | `infixl 7` | `Data.Int`: multiplication |
| `+` `-` | `infixl 6` | `Data.Int`: addition, subtraction |
| `:` | `infixr 5` | the list constructor `Cons` |
| `==` `!=` | `infix 4` | `Eq` methods |
| `<` `<=` `>` `>=` | `infix 4` | `Ord` methods |
| `~` `!~` | `infix 4` | regex match, and its negation |
| `&&` | `infixr 3` | `Data.Bool`: conjunction |
| `<\|>` | `infixl 3` | `Alternative`: `alt` |
| `\|\|` | `infixr 2` | `Data.Bool`: disjunction |
| `>>` | `infixl 1` | `Control.Monad`: sequencing |
| `$` | `infixr 0` | `Data.Function`: application |
| `\|` | left, looser than every other operator | `Control.Category`: composition left to right |

`&&` and `||` are ordinary functions, defined by `case`, so each is lazy
in its right operand. TQL has no `/` and no negation; see
[Integers](10-evaluation.md#integers).

## Sections

```
(op)      =   \x y -> x op y
(e op)    =   let v = e in \y -> v op y
(op e)    =   let v = e in \x -> x op v
```

`e` is evaluated at most once, however often the section is applied.

A left section `(e op)` is legal when `e op x` groups as `(e) op x`, and
a right section `(op e)` when `x op e` groups as `x op (e)`. So
`(* 2 + 3)` is an error, and `(+ 2 * 3)` is `\x -> x + 2 * 3`.

`(- e)` is a right section of subtraction: `(- 1) 5` is `4`.

A section of `:` is written with a space, `(: xs)`, since `(:xs)` is a
kind literal.

## Lambda abstraction

```
\p1 ... pn -> e   =   \x1 -> ... \xn -> case (x1, ..., xn) of { (p1, ..., pn) -> e }
```

When every `pi` is a variable, the `case` is left out. Each `pi` must be
exhaustive by the [coverage judgement](03-patterns.md#coverage), or the
lambda is an error. A variable bound twice among `p1 ... pn` is an error.

## Conditionals

```
if e1 then e2 else e3   =   case e1 of { True -> e2; False -> e3 }
```

## Case

```
case e of { p1 if g1 -> e1; ...; pn -> en }
```

The alternatives are tried in order. The first whose pattern matches and
whose guard, if it has one, is `True` gives the result. A guard that is
`False` passes the value on to the next alternative. The meaning of a
match is in [Patterns](03-patterns.md#meaning).

A `case` whose alternatives do not cover every value is an error
(`non-exhaustive`), and so is one with an alternative no value can reach
(`redundant-alternative`). See [Coverage](03-patterns.md#coverage).

## Let

```
let { b1; ...; bn } in e
let b1; ...; bn in e
```

The two forms are the same. The bindings are one recursive group: each
`bi` is in scope in every `bj` and in `e`. The group is split by
dependency before it is typed ([Binding groups](04-declarations.md#binding-groups)).
A name bound twice in one group is an error.

A binding `f p1 ... pn = e` is `f = \p1 ... pn -> e`. Several adjacent
clauses of one name form one definition
([Function bindings](04-declarations.md#function-bindings)).

A pattern binding `p = e` binds lazily:

```
let { p = e; bs } in e'   =   let { t = e; x1 = case t of { p -> x1 }; ...; xk = case t of { p -> xk }; bs } in e'
```

where `x1 ... xk` are the variables of `p`. `p` must be exhaustive.

## Do

`do` works in any monad.

```
do { e }               =   e
do { e; ss }           =   e >> do { ss }
do { p <- e; ss }      =   bind e (\x -> case x of { p -> do { ss }; _ -> empty })
do { p <- e; ss }      =   bind e (\x -> case x of { p -> do { ss } })        if p is exhaustive
do { let bs; ss }      =   let bs in do { ss }
```

A bind whose pattern can fail falls through to `empty`, so it requires
`Alternative`. One whose pattern cannot fail requires only `Monad`.

The last statement is an expression. A block that is empty, or that ends
with a bind or a `let`, is a parse error.

At `Filter Node`, every statement runs on the block's input:

```tql
main = do {
  c <- descendants_of_kind :class_declaration;
  n <- descendants_of_kind :method_definition;
  pure (text c, text n);
};
```

Both statements read the root, not the class. To run a step on a bound
node, pipe it: `n <- pure c | descendants_of_kind :method_definition;`.

## Pipelines

```
p | q   =   (|) p q
```

`(|) :: Category k => k a b -> k b c -> k a c` is composition left to
right. At `Filter`, the composite runs `q` on each output of `p` and
concatenates the results in order:

```
run (p | q) x   =   concat_map (run q) (run p x)
```

## Lists and tuples

```
[e1, ..., en]      =   e1 : ... : en : []
(e1, ..., en)      =   (,...,) e1 ... en          2 ≤ n ≤ 255
```

`[]` is `Nil` and `:` is `Cons`. `()` is the unit value. There are no
one-tuples, tuple sections, arithmetic sequences or list comprehensions.

## Records

```
{l1 = e1, ..., ln = en}     a record with fields l1 ... ln
e.l                         the field l of e
(.l1. ... .ln)              =   \r -> r.l1. ... .ln
```

Field order does not matter: `{a = 1, b = 2}` and `{b = 2, a = 1}` are
the same value. A label repeated in one literal is an error. `{}` is the
empty record. Record types are in [Records and rows](05-types.md#records-and-rows).

## Field navigation

`n#f` is the list of `n`'s children in the grammar field `f`, in document
order. `#f` on its own is the filter of that step:

```
#f   =   Kleisli (\n -> n#f)
```

So `descendants_of_kind :call_expression | #function` yields each call's
callee. See [Fields](09-tree.md#fields).

## Type annotations

```
(e :: σ)
```

checks `e` against `σ` and has type `σ`. The type variables of `σ` are
quantified at the annotation, not shared with an enclosing signature. See
[T-Ann](06-static-semantics.md#annotations).
