# For Haskell programmers

TQL is built on Haskell's principles and much of its syntax, so a Haskell
programmer can read most queries on sight. Its goals are its own, and
where they call for something different, TQL does it differently. This
chapter lists the differences most likely to surprise someone who expects
Haskell.

## Syntax

- **Braces and semicolons, no layout.** Every block is braced and every
  item ends with `;`.
- **`|` is the pipe.** It composes query steps left to right, binds looser
  than every other operator, `$` included, and groups to the left. So a
  step can take its argument with `$`: `f $ x | g` is `(f $ x) | g`.
- **Guards are `p if c -> e`.** `|` is taken by the pipe.
- **`!=`, not `/=`**, matching `!~`.
- **No `/` and no negation.** Integer division is `div` or `quot`, named
  for how they round. `-1` is a literal, `(- 1)` is a section, and `-x` is
  an error.
- **Kind literals `:k` and fields `#f`.** Node kinds and grammar fields
  are part of the language. `x :xs` applies `x` to a kind, while
  `x : xs` and `x:xs` are cons.
- **Trailing separators** are accepted in every group.

## Patterns

- **Conjunction `p & q`** matches both patterns; `x@p` is its case with a
  variable.
- **Views `(e -> p)`, node patterns and field patterns** are ordinary
  patterns.
- **A pattern that can fail is an error** in a lambda, `let` or definition
  head. A TQL program never fails a match at run time.
- **A non-exhaustive or redundant `case` is an error.**

## Types and classes

- **A failing `do` bind falls through to `empty`.** There is no
  `MonadFail`: TQL has no error strings, so failure is `empty`.
- **No orphan instances, and one instance per class and type.** An
  instance lives with its class or its type, so a program's instances
  never depend on which modules it happens to import.
- **No defaulting.** A type that nothing determines is an error.
- **Literals are not overloaded.** An integer literal is an `Int`, and
  there is no `Num`.
- **Records are anonymous and structural.** A function can accept any
  record with the fields it needs, and records get class instances from
  their fields.
- **`Filter` is `Kleisli List`**, the type of a query step.
- **Method names are words** (`map`, `bind`, `ap`, `alt`, `append`). The
  comparison methods are operators.

## Programs and evaluation

- **`main` is a `Filter Node t` with `ToJSON t`.** A program runs once per
  file and its output is JSON. There is no `IO`.
- **`String` is UTF-8 text**, not a list of characters. There is no
  `Char`.
- **`Int` arithmetic is total.** It wraps on overflow, and a zero divisor
  gives quotient `0` and the dividend as remainder, so `q * b + r == a`
  always holds.
- **No `error`, `undefined` or exceptions.** A partial function returns
  `Maybe`.
- **No lazy `foldl`.** `foldl'` is the left fold.
- **Regular expressions are built in**, in a dialect that matches in
  linear time, since target files are untrusted input.

## Modules

- **A module's own declaration hides an import** of the same name, so a
  name added to the `Prelude` never breaks an existing query.
- **`import M as Q` imports qualified only.** There is no `qualified`
  keyword.
- **Modules may import each other in a cycle**, with nothing written
  twice.
