# Expressions

## Notation

| Letter | Ranges over |
|---|---|
| `e` | expressions |
| `x`, `y`, `f` | variables |
| `lit` | literals |
| `op` | operators |
| `p` | patterns |
| `g` | guards |
| `b`, `bs` | bindings, and sequences of them |
| `ss` | sequences of statements |
| `l` | record labels |
| `f`, in `n#f` and `#f` | fields |
| `n` | nodes |
| `σ` | type schemes |

## Grammar

```
exp     ::= lexp (qop lexp)*

lexp    ::= blockexp | fexp
blockexp ::= "\" apat+ "->" exp
          | "let" binds "in" exp
          | "if" exp "then" exp "else" exp
          | "case" exp "of" "{" (alt ";")* "}"
          | "do" "{" (stmt ";")* exp ";" "}"

fexp    ::= fexp arg | aexp
arg     ::= aexp | blockexp

aexp    ::= qvar | qcon | primitive | literal
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
stmt    ::= exp | pat "<-" exp | "let" "{" (decl ";")* "}" | "let" decl (";" decl)*
binds   ::= "{" (decl ";")* "}" | (decl ";")+
```

A lambda, `let`, `if` or `case` extends as far to the right as it can. Any
of them, and `do`, may be a function argument without brackets:
`map \x -> x + 1`, `f do { ... }`.

Application is left-associative and binds tighter than every operator.
Field selection `x.f` and field navigation `n#f` bind tighter than
application, so `range n.start` is `range (n.start)`.

## The expression kernel

Every expression translates to a kernel expression:

```
e ::= x                                   variable
    | lit                                 literal
    | \x -> e                             abstraction
    | e e                                 application
    | let { x = e; ... } in e             recursive binding group
    | case e of { p -> e; ... }           match over kernel patterns
    | (e :: σ)                            annotation
```

A kernel expression is written in source syntax. A variable `x` includes
the kernel constants the translations introduce, `record_L`, `select_l`
and `field_f`, and the primitives. Without those, a kernel expression is
a program fragment. Kernel patterns are in
[The pattern kernel](03-patterns.md#the-pattern-kernel), the typing rules
in [Static semantics](06-static-semantics.md), and the meaning in
[Evaluation](10-evaluation.md).

Each construct is given as a translation, an equation read left to right.
Its right side is a kernel expression, except that it may apply the
translation to smaller source terms. A name on the right that the left
does not bind is fresh, and a library name on the right (`bind`, `empty`,
`Cons`) is the one the `Prelude` exports, whatever the program's own scope
holds.

A source construct is well typed exactly when its translation is, and
means what its translation means. The checker reads the source as
written, so it reports an error at the construct, not at its
translation.

## Variables, constructors and literals

A variable or constructor denotes its binding in scope
([Name resolution](07-modules.md#name-resolution)). A literal denotes its
value at its type ([Literals](01-lexical.md#literals)).

## Operator application

`(op)` names the operator's binding as a variable. An operator
application applies it:

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
  associativities differ, are a parse error. `a < b < c` and
  `a && b <|> c` are parse errors; bracket one side.

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
| `~` `!~` | `infix 4` | `Data.Regex`: match, and its negation |
| `&&` | `infixr 3` | `Data.Bool`: conjunction |
| `<\|>` | `infixl 3` | `Alternative`: `alt` |
| `\|\|` | `infixr 2` | `Data.Bool`: disjunction |
| `>>` | `infixl 1` | `Control.Monad`: sequencing |
| `$` | `infixr 0` | `Data.Function`: application |
| `\|` | `infixl -1` | `Control.Category`: composition left to right |

`&&` and `||` are ordinary functions, defined by `case`, so each is lazy
in its right operand. TQL has no `/` and no negation; see
[Int](11-library.md#int).

## Section

```
(e op)    =   let { v = e; } in \y -> (op) v y
(op e)    =   let { v = e; } in \x -> (op) x v
```

`e` is evaluated at most once, however often the section is applied.

A left section `(e op)` is legal when `e op x` groups as `(e) op x`, and
a right section `(op e)` when `x op e` groups as `x op (e)`. So
`(* 2 + 3)` is a parse error, and `(+ 2 * 3)` is `\x -> x + 2 * 3`.

`(- e)` is a right section of subtraction: `(- 1) 5` is `4`.

A section of `:` is written with a space, `(: xs)`, since `(:xs)` is a
kind literal.

## Lambda abstraction

```
\p1 ... pn -> e   =   \x1 -> ... \xn -> case (x1, ..., xn) of { (p1, ..., pn) -> e; }
```

When every `pi` is a variable, the `case` is left out. Each `pi` must be
exhaustive by the [coverage judgement](03-patterns.md#coverage), or the
lambda is an error, `non-exhaustive`. A variable bound twice among
`p1 ... pn` is an error, `duplicate-definition`.

## Conditional expression

```
if e1 then e2 else e3   =   case e1 of { True -> e2; False -> e3; }
```

## Case expression

```
case e of { p1 if g1 -> e1; ...; pn -> en; }
```

The alternatives are tried in order. The first whose pattern matches and
whose guard, if it has one, is `True` gives the result. A guard that is
`False` passes the value on to the next alternative. The meaning of a
match is in [Patterns](03-patterns.md#meaning).

A `case` whose alternatives do not cover every value is an error,
`non-exhaustive`, and one with an alternative no value can reach is an
error, `redundant-alternative` ([Coverage](03-patterns.md#coverage)).

## Let expression

```
let { b1; ...; bn; } in e
let b1; ...; bn; in e
```

The two forms are the same. The bindings are recursive: each `bi` is in
scope in every `bj` and in `e`. They are split into binding groups by
dependency and typed group by group
([Binding group](05-declarations.md#binding-group)).
A name bound twice in one `let` is an error, `duplicate-definition`.

A binding `f p1 ... pn = e` is `f = \p1 ... pn -> e`. Several adjacent
clauses of one name form one definition
([Function binding](05-declarations.md#function-binding)).

A pattern binding `p = e` binds lazily:

```
let { p = e; bs } in e'   =   let { t = e; x1 = case t of { p -> x1; }; ...; xk = case t of { p -> xk; }; bs } in e'
```

where `x1 ... xk` are the variables of `p`. `p` must be exhaustive, or
the binding is an error, `non-exhaustive`.

## Do expression

`do` works in any monad.

```
do { e; }              =   e
do { e; ss }           =   (>>) e (do { ss })
do { p <- e; ss }      =   bind e (\x -> case x of { p -> do { ss }; _ -> empty; })
do { p <- e; ss }      =   bind e (\x -> case x of { p -> do { ss }; })        if p is exhaustive
do { let bs; ss }      =   let { bs } in do { ss }
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

Both statements read the root, not the class. To run a filter on a
bound node, pipe it: `n <- pure c | descendants_of_kind :method_definition;`.

## Pipeline

```
e1 | e2   =   (|) e1 e2
```

`(|) :: Category k => k a b -> k b c -> k a c` is composition left to
right. At `Filter`, the composite runs `e2` on each output of `e1` and
concatenates the results in order:

```
run (e1 | e2) x   =   concat_map (run e2) (run e1 x)
```

## List and tuple

```
[e1, ..., en]      =   Cons e1 (... (Cons en Nil))
(e1, ..., en)      =   (,...,) e1 ... en          2 ≤ n ≤ 255
```

`[]` is `Nil` and `:` is `Cons`. `()` is the tuple of no components, the
unit. There are no one-tuples, tuple sections, arithmetic sequences or
list comprehensions.

## Record

```
{l1 = e1, ..., ln = en}     =   record_{l1 ... ln} e1 ... en      l1 < ... < ln
e.l                         =   select_l e
(.l1. ... .ln)              =   \r -> r.l1. ... .ln
```

A literal's fields are sorted by label first, so `{a = 1, b = 2}` and
`{b = 2, a = 1}` are the same value. A label repeated in one literal is
an error, `duplicate-definition`. `{}` is the empty record. `record_L`
and `select_l` are kernel constants, one for each set of labels and each
label; a program cannot name them. Their types are in
[Records and rows](04-types.md#records-and-rows).

## Field navigation

```
n#f   =   field_f n
#f    =   Kleisli field_f
```

`field_f :: Node -> [Node]` is a kernel constant, one for each field of
the target grammar, giving a node's children in field `f`
([Fields](09-tree.md#fields)). A program cannot name it.
`descendants_of_kind :call_expression | #function` yields each call's
callee.

## Type annotation

```
(e :: σ)
```

checks `e` against `σ` and has type `σ`. The type variables of `σ` are
quantified at the annotation, not shared with an enclosing signature. See
[T-Ann](06-static-semantics.md#annotations).
