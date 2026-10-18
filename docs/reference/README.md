# The TQL language reference

This reference defines TQL 0.5. Each construct is given as a
translation to a smaller language, the kernel, and the kernel is given its
typing rules and its meaning.

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

Each construct is given as a translation to the kernel
([expressions](02-expressions.md#the-expression-kernel),
[patterns](03-patterns.md#the-pattern-kernel)). A translation is an
equation read left to right. Its right side is a kernel term, written in
source syntax, except that it may apply the translation being defined to
smaller source terms. A name on the right that the left does not bind is
fresh, and a library name on the right (`bind`, `empty`, `Cons`) is the
one the `Prelude` exports, whatever the program's own scope holds.

```
do { e; ss }   =   (>>) e (do { ss })
```

Library definitions are written as `tql` code. Laws, which are equations
between meanings, are written in plain blocks.

Typing rules are written as fractions. Premises are above the line and the
conclusion below. Each rule has a name, which corpus cases cite.

```
(X-Name)  premise1     premise2
          ─────────────────────
          conclusion
```

Judgements:

| Form | Reads |
|---|---|
| `Γ ⊢ e ⇒ τ ⇝ W` | `e` infers type `τ`, provided `W` holds |
| `Γ ⊢ e ⇐ τ ⇝ W` | `e` checks against `τ`, provided `W` holds |
| `Γ ⊢ p : τ ⊣ Δ` | `p` matches a `τ` and binds `Δ` |
| `Γ ⊢ bs ⊣ Γ' ⇝ W` | the bindings `bs` give the schemes `Γ'`, leaving `W` |
| `Q ⊩ π ⇝ d` | the givens `Q` entail `π`, with evidence `d` |
| `Ψ ⊢ τ : κ` | `τ` has kind `κ` |

`⇒` is only the inference judgement. Types and schemes write `=>`:
`∀ā. Q => τ`.

Metavariables:

| Letter | Ranges over |
|---|---|
| `e` | expressions |
| `p`, `q` | patterns, and filters in laws |
| `x`, `y`, `f` | variables |
| `v` | values |
| `lit` | literals |
| `l` | record labels |
| `K` | constructors |
| `N` | newtype constructors |
| `P` | pattern synonyms |
| `T` | type constructors |
| `C`, `S` | classes |
| `τ` | types |
| `σ` | type schemes |
| `ρ` | rows |
| `a`, `b`, `r` | type variables, `r` a row variable |
| `α`, `β` | fresh type variables |
| `κ` | kinds |
| `π` | class constraints |
| `Q` | givens |
| `W` | wanteds |
| `d` | evidence |
| `Γ` | type environments |
| `Δ` | pattern bindings |
| `Ψ` | kind environments |
| `bs`, `ss` | sequences of bindings and of statements |

A bar marks a sequence: `ā` is `a1 ... an`.

Terms:

| Term | Means |
|---|---|
| datatype | a type declared by `data` or `newtype` |
| filter | a value of type `Filter a b` |
| binding group | a strongly connected component of bindings, typed together |
| component | a strongly connected component of the import graph |
| target file | a file a program runs on |
| target grammar | the grammar the target files are parsed with |

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
(`Expressions: Do expression`).
