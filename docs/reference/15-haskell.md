# For Haskell programmers

TQL is built on Haskell's principles and much of its syntax, so a Haskell
programmer can read most queries on sight. Where its own goals call for
something different, TQL does it differently. This chapter lists the
differences most likely to surprise someone who expects Haskell. Each
links to the rule it summarises.

## Syntax

- **Braces and semicolons, no layout.** Every block is braced and every
  item ends with `;`, the last one included, and a trailing `,` is
  accepted in every comma-separated group
  ([Lexical structure](01-lexical.md)).
- **`|` is the pipe.** It composes filters left to right, groups to the
  left, and binds looser than every standard library operator, `$`
  included, so a filter can take its argument with `$`: `f $ x | g` is
  `(f $ x) | g` ([Operator application](02-expressions.md#operator-application)).
- **Guards are `p if c -> e`**, since `|` is the pipe
  ([Case expression](02-expressions.md#case-expression)).
- **`!=`, not `/=`**, matching `!~`
  ([Operator application](02-expressions.md#operator-application)).
- **No negation.** `-1` is a literal, `(- 1)` is a section, and `-x` is
  a parse error ([Operators](01-lexical.md#operators)).
- **Kind literals `:k` and fields `#f`.** Node kinds and grammar fields
  are part of the language. `x :xs` applies `x` to a kind, while
  `x : xs` and `x:xs` are cons ([Operators](01-lexical.md#operators),
  [The tree](09-tree.md)).

## Patterns

- **Conjunction `p & q`** matches both patterns; `x@p` is its case with a
  variable ([The pattern kernel](03-patterns.md#the-pattern-kernel)).
- **Views `(e -> p)`, node patterns and field patterns** are ordinary
  patterns ([The pattern kernel](03-patterns.md#the-pattern-kernel)).
- **Incomplete and redundant matches are errors.** A pattern that can
  fail is an error in a lambda, `let` or definition head, and a
  non-exhaustive or redundant `case` is an error. A TQL program never
  fails a match at run time ([Coverage](03-patterns.md#coverage)).
- **A failing `do` bind falls through to `empty`.** There is no
  `MonadFail` ([Do expression](02-expressions.md#do-expression)).

## Types and classes

- **No defaulting.** A constrained type variable that nothing determines
  is an error, `ambiguous-constraint`
  ([Ambiguity](06-static-semantics.md#ambiguity)).
- **Literals are not overloaded.** An integer literal is an `Int`, and
  there is no `Num` ([Expressions](06-static-semantics.md#expressions)).
- **Records are anonymous and structural.** A function can accept any
  record with the fields it needs, and a record gets class instances from
  its fields ([Records and rows](04-types.md#records-and-rows)).
- **`Filter` is `Kleisli List`**, the type of a query
  ([Filters](11-library.md#filters)).
- **`minimal` is a declaration in the class body**, not a pragma, and an
  instance that defines too few methods is an error, not a warning
  ([Class](05-declarations.md#class)).
- **A class names its own deriver** in its body, so deriving is a
  library declaration. A library class can also be derived through a
  generic representation of the datatype. There is no `DeriveAnyClass`
  ([Deriving](05-declarations.md#deriving)).
- **One instance per class and type, and no orphans.** An instance lives
  with its class or its type, so a program's instances never depend on
  which modules it imports ([Instance](05-declarations.md#instance)).
- **Method names are words** (`map`, `bind`, `ap`, `alt`, `append`),
  except the comparison methods, which are operators
  ([Predefined types and classes](11-library.md)).

## Programs and values

- **`main` is a `Filter Node t` with `ToJson t`.** A program runs once
  per file and its output is JSON. There is no `IO`
  ([Programs](08-programs.md)).
- **`String` is UTF-8 text**, not a list of characters. There is no
  `Char` ([Standard types](11-library.md#standard-types)).
- **`Int` arithmetic is total.** It wraps on overflow. There is no `/`:
  integer division is `div` or `quot`, named for how they round. A zero
  divisor gives quotient `0` and the dividend as remainder, so
  `q * b + r == a` always holds ([Int](11-library.md#int)).
- **No `error`, `undefined` or exceptions.** A partial function returns
  `Maybe` ([Runtime errors](10-evaluation.md#runtime-errors)).
- **No lazy `foldl`.** `foldl'` is the left fold
  ([Foldable and Traversable](11-library.md#foldable-and-traversable)).
- **Regular expressions are built in**, in a dialect that matches in
  linear time ([Regex](11-library.md#regex)).

## Modules

- **Names resolve in layers**: a module's own declaration hides an
  import, a listed import hides a whole-module import, and any import
  hides the implicit `Prelude`. A name added to the `Prelude` never
  breaks a query that imports it implicitly
  ([Name resolution](07-modules.md#name-resolution)).
- **`import M as Q` imports qualified only.** There is no `qualified`
  keyword ([Imports](07-modules.md#imports)).
- **Modules may import each other in a cycle**, with nothing written
  twice ([Import cycles](07-modules.md#import-cycles)).
