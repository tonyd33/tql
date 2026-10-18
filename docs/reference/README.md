# The TQL language reference

This reference defines TQL 0.5. Each construct is given as a
translation to a smaller language, the kernel, and the kernel is given its
typing rules and its meaning. Each chapter defines the notation it uses.

TQL is built for querying syntax trees. Its foundation comes from Haskell and
GHC: a lazy, typed functional core, type classes, and decades of research on
making them sound. TQL takes those principles and applies them to its own
goals. A reader who knows Haskell will find the differences that matter most in
[For Haskell programmers](15-haskell.md).

## Foundations

TQL stands on the work of many languages and papers.

Haskell and GHC give the core: a lazy, typed functional language with
type classes.

- The Haskell 2010 Report, whose form this reference follows: each
  construct as a translation to a kernel.
- OutsideIn(X) (Vytiniotis, Peyton Jones, Schrijvers and Sulzmann, JFP
  2011), for the checker's constraints and implications.
- Safe coercions and roles (Breitner, Eisenberg, Peyton Jones and
  Weirich, ICFP 2014), for newtypes.
- GHC's extensions `BlockArguments`, `LexicalNegation`,
  `OverloadedRecordDot`, `ViewPatterns`, `PatternSynonyms`,
  `MonoLocalBinds`, `DerivingStrategies` and `DeriveGeneric`, for the
  syntax and rules of the same names.
- GHC's Core, its optimiser and its rewrite rules, for typed Core.
- Compiling without continuations (Maurer, Downen, Ariola and Peyton
  Jones, PLDI 2017), for join points.
- Launchbury's natural semantics for lazy evaluation (POPL 1993) and
  Abramsky's lazy lambda calculus, for the meaning of evaluation.

Patterns:

- Maranget's usefulness (JFP 2007) and Lower Your Guards (Graf, Peyton
  Jones and Scott, ICFP 2020), for coverage.
- F#, for conjunction patterns `p & q`.
- Rust and Scala, for `if` guards in a match, and Rust for treating a
  non-exhaustive match as an error.

Records:

- PureScript, for anonymous row-polymorphic records and the `{l: t | r}`
  syntax.
- The `row-types` library and Hubers and Morris (ICFP 2023), for classes
  over rows, `All C r`.

Modules and names:

- PureScript, for qualified-only `import M as Q`, local declarations that
  hide imports, and the library's method names (`map`, `bind`, `ap`,
  `alt`, `append`).

Queries:

- jq and the Unix shell, for `|` as the pipe; F# and OCaml, for a pipe
  that binds loosest.
- XPath, for navigation as an axis and a node test.
- tree-sitter, for the trees TQL queries.

Values:

- Lean 4 and Coq, for division that is total at a zero divisor.
- RE2 and Rust's `regex`, for regular expressions matched in linear time.
- The Unicode Standard, for replacing ill-formed UTF-8 with U+FFFD.
- aeson, for the JSON encoding of datatypes.

## Chapters

1. [Lexical structure](01-lexical.md)
2. [Expressions](02-expressions.md)
3. [Patterns](03-patterns.md)
4. [Types](04-types.md)
5. [Declarations and bindings](05-declarations.md)
6. [Static semantics](06-static-semantics.md)
7. [Modules](07-modules.md)
8. [Programs](08-programs.md)
9. [The tree](09-tree.md)
10. [Evaluation](10-evaluation.md)
11. [Predefined types and classes](11-library.md)
12. [Typed Core and the optimiser](12-core.md)
13. [Syntax reference](13-syntax.md)
14. [Errors](14-errors.md)
15. [For Haskell programmers](15-haskell.md)

