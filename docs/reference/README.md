# The TQL language reference

This reference defines TQL 0.5. Each construct is given as a
translation to a smaller language, the kernel, and the kernel is given its
typing rules and its meaning.

TQL is built for querying syntax trees. Its foundation comes from Haskell and
GHC: a lazy, typed functional core, type classes, and decades of research on
making them sound. TQL takes those principles and applies them to its own
goals. A reader who knows Haskell will find the differences that matter most in
[For Haskell programmers](12-haskell.md).

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
4. [Declarations and bindings](04-declarations.md)
5. [Types and classes](05-types.md)
6. [Static semantics](06-static-semantics.md)
7. [Modules](07-modules.md)
8. [Programs](08-programs.md)
9. [The tree](09-tree.md)
10. [Evaluation](10-evaluation.md)
11. [The standard library](11-library.md)
12. [For Haskell programmers](12-haskell.md)
13. [Typed Core and the optimiser](13-core.md)

## Notation

Grammar productions use this notation:

```
x?        optional
x*        zero or more
x+        one or more
x | y     choice
(x y)     grouping
"k"       a literal token
```

Translations are equations between source forms, read left to right. A
name on the right that the left does not bind is fresh. `case`, `let`
and `\` on the right are kernel forms, and the library names
on the right (`bind`, `empty`, `Cons`) are the ones the `Prelude` exports,
whatever the program's own scope holds.

```
do { e; ss }   =   e >> do { ss }
```

Typing rules are written as fractions. Premises are above the line and the
conclusion below. Each rule has a name, which corpus cases cite.

```
(T-App)   Γ ⊢ e1 ⇒ τ1 -> τ2     Γ ⊢ e2 ⇐ τ1
          ──────────────────────────────────
          Γ ⊢ e1 e2 ⇒ τ2
```

Rule-name prefixes:

| Prefix | Judgement |
|---|---|
| `T-` | typing of expressions and bindings |
| `P-` | typing of patterns |
| `K-` | kinding of types |
| `E-` | entailment of constraints |
| `M-` | meaning of a pattern match |
| `C-` | typing of Core |

A corpus case names the rule it tests by its name (`T-App`), or by its
chapter and section heading when the rule is a translation
(`Expressions: do`).

## The kernel

Every program translates to a small language. Its expressions are:

```
e ::= x                                   variable
    | l                                   literal
    | \x -> e                             abstraction
    | e e                                 application
    | let { x = e; ... } in e             recursive binding group
    | case e of { p -> e; ... }           match over kernel patterns
    | (e :: σ)                            annotation
```

Its patterns are in [Patterns](03-patterns.md#the-pattern-kernel).

A source construct is well typed exactly when its translation is, and
means what its translation means. The checker reads the source as
written, so it reports an error at the construct, not at its
translation. Match compilation, operator lowering and dictionary passing
run after the checker and produce [typed Core](13-core.md).
