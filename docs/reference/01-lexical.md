# Lexical structure

A source file is UTF-8 text. A file that is not well-formed UTF-8 is a
parse error.

TQL has no layout rule. Blocks are written with braces, and every
declaration, binding, statement and alternative ends with `;`, the last
one included. `,` separates, and every comma-separated group accepts a
trailing `,`: `[1, 2,]` and `{a = 1,}` are legal.

## Comments

`--` starts a comment that runs to the end of the line, unless the dashes
are part of a longer operator symbol such as `-->` or `--|`. There are no
block comments.

## Names

```
lower      ::= [a-z] [a-zA-Z0-9_']*   |   _ [a-zA-Z0-9_']+
upper      ::= [A-Z] [a-zA-Z0-9_']*
qualified  ::= (upper ".")+ (lower | upper)
primitive  ::= "%" (lower | upper)
```

A lower name names a value or a type variable: `x`, `foldl'`, `_x`. An
upper name names a constructor, type, class or module. A qualified name is
one token: `Data.List.map`, `Data.Maybe.Maybe`. A primitive name names a
primitive ([The library](07-modules.md#the-library)).

`_` alone is the wildcard. It is a token, not a name: in a pattern it
matches anything and binds nothing, and anywhere a name would be bound or
used it is a parse error.

## Keywords

These are reserved and cannot be names:

```
case class data deriving do else if import in infix infixl infixr
instance let module newtype of then type where
```

`as`, `hiding`, `for`, `forall`, `pattern` and `rule` are keywords only where the
grammar expects them, and ordinary names elsewhere. `minimal` is a
keyword in a class body, so no method is named `minimal`, and an
ordinary name elsewhere.

## Operators

An operator symbol is a sequence of the characters

```
! # $ % & * + . / < = > ? @ ^ | ~ - :
```

that is not a reserved symbol:

```
=   ::   ->   <-   =>   \   ;   ,   @   #   :   ..
```

A reserved symbol is syntax and never an operator. These operator
symbols are also syntax in certain positions, and operators elsewhere:

| Symbol | Syntax where |
|---|---|
| `\|` | between constructors, in a `minimal` formula, and before a row's tail |
| `!` | directly before a pattern: a bang |
| `&` | between patterns: a conjunction |
| `%` | directly before a name: a primitive name |

An operator means its binding in scope and has the fixity of its
declaration ([Fixity](05-declarations.md#fixity)).

An occurrence of `.`, `#`, `@`, `:` or `-` reads by its neighbours. Its
left side is open when whitespace or one of `( [ { , ;` precedes it, and
its right side is open when whitespace or one of `) ] } , ;` follows it.
The occurrence is:

| Left | Right | Occurrence |
|---|---|---|
| closed | closed | tight infix |
| open | closed | prefix |
| closed | open | suffix |
| open | open | loose infix |

| Character | Tight infix | Prefix | Suffix | Loose infix |
|---|---|---|---|---|
| `.` | field selection, `x.f` | a selector `(.f)`, directly after `(`; otherwise a parse error | the end of a rule's `forall`; otherwise a parse error | composition, `f . g` |
| `#` | field children, `n#f` | a field filter, `#f` | a parse error | a parse error |
| `@` | an as-pattern, `x@p` | a parse error | a parse error | a parse error |
| `:` | cons | a kind literal `:k`, before a name; otherwise cons | cons | cons |
| `-` | subtraction | a negative literal, before a digit; otherwise a parse error | subtraction | subtraction |

So `x:xs` and `x : xs` are cons, and `x :xs` applies `x` to the kind
`:xs`. `f -1` is `f` applied to `-1`, and `x - 1`, `x-1` and `x- 1` are
subtractions. `(. f)` and `(- 1)` are right sections. `-x` is a parse error,
since TQL has no negation; write `0 - x`.

## Literals

```
integer  ::= "-"? [0-9]+
string   ::= '"' (char | escape)* '"'
escape   ::= \"  |  \\  |  \n  |  \t  |  \r
regex    ::= 'r"' raw* '"'
kindlit  ::= ":" [a-zA-Z_] [a-zA-Z0-9_]*
```

An integer literal has type `Int`. One outside the range of a 64-bit
two's complement integer is a parse error.

A string literal has type `String`. An escape not in the list is a parse
error.

A regex literal has type `Regex`. Its body is raw: `r"a\b"` passes the
backslash to the pattern. The body is compiled with the program, and a
pattern outside the [regex dialect](11-library.md#regex) is an error,
`invalid-regex`.

A kind literal has type `Kind`. What it names is in
[Kinds](09-tree.md#kinds).

There are no character or floating-point literals.
