# Lexical structure

A source file is UTF-8 text. A file that is not well-formed UTF-8 is a
parse error.

TQL has no layout rule. Blocks are written with braces, and every
declaration, binding, statement and alternative ends with `;`. A
trailing separator is accepted in every group: `[1, 2,]`, `{a = 1,}` and
a `;` after the last alternative are all legal.

## Comments

`--` starts a comment that runs to the end of the line, unless the dashes
are part of a longer operator symbol. `-->` and `--|` are operators. There
are no block comments.

## Identifiers

```
lower      ::= [a-z] [a-zA-Z0-9_']*   |   _ [a-zA-Z0-9_']+
upper      ::= [A-Z] [a-zA-Z0-9_']*
qualified  ::= (upper ".")+ (lower | upper)
```

A lower name names a value or a type variable. An upper name names a
constructor, type, class or module. A qualified name is one token:
`Data.List.map`, `Data.Maybe.Maybe`.

`'` may follow the first character: `foldl'`, `x''`.

`_` alone is the wildcard. It is a token, not a name: in a pattern it
matches anything and binds nothing, and anywhere a name would be bound or
used it is an error. `_x` is an ordinary name.

A name beginning with `%` names a primitive. Primitive names resolve only
in the `Prim` module.

## Keywords

These are reserved and cannot be names:

```
case class data deriving do else if import in instance let
module newtype of then type where
```

`as`, `hiding`, `for` and `pattern` are keywords only where the grammar
expects them, and are ordinary names elsewhere.

## Operators

An operator symbol is a sequence of the characters

```
! # $ % & * + . / < = > ? @ ^ | ~ - :
```

that is not one of the reserved symbols:

```
=   ::   ->   <-   =>   \   ;   ,   @   #   :
```

The meaning of an operator comes from its binding in scope; its fixity
comes from its declaration ([Fixity](04-declarations.md#fixity)).

Some characters read differently depending on whether a space separates
them from their neighbours.

| Form | Reads as |
|---|---|
| `x.f`, `x.f.g` | record field selection |
| `f . g` | composition |
| `(.f)`, `(.f.g)` | a selector: `\r -> r.f` |
| `(. f)` | a right section of composition |
| `x .f`, `x. y` | an error |
| `n#f` | the children of `n` in field `f` |
| `#f` | a field step: the filter `\n -> n#f` |
| `x@p` | an as-pattern |
| `x @p`, `x@ p` | an error |
| `%` directly before a name | a primitive name |
| `:k` directly before a name | a kind literal |
| any other `:` | cons |
| `-` directly before a digit, not after an operand | part of a negative literal |
| `-` before anything else, not after an operand | an error: TQL has no negation |

So `x:xs` and `x : xs` are cons, and `x :xs` applies `x` to the kind
`:xs`. `f -1` is `f` applied to `-1`, and `x - 1`, `x-1` and `x- 1` are
subtractions. `(- 1)` is a right section of subtraction. `-x` is an
error; write `0 - x`.

## Literals

```
integer  ::= "-"? [0-9]+
string   ::= '"' (char | escape)* '"'
escape   ::= \"  |  \\  |  \n  |  \t  |  \r
regex    ::= 'r"' raw* '"'
kind     ::= ":" [a-zA-Z_] [a-zA-Z0-9_]*
```

An integer literal has type `Int`. One outside the range of a 64-bit
two's complement integer is a parse error.

A string literal has type `String`. An escape not in the list is a parse
error.

A regex literal has type `Regex`. Its body is raw, so `r"a\b"` passes the
backslash to the pattern. The body is compiled when the program is, and a
pattern outside the [regex dialect](10-evaluation.md#regular-expressions)
is a compile error.

A kind literal has type `Kind`. It names a node kind of the target
grammar, and an unknown kind is a compile error
([Kinds](09-tree.md#kinds)).

There are no character or floating-point literals.
