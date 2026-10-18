# Errors

Every error has a code. This chapter indexes them; each rule is stated
where it is linked.

A program that does not match the [grammar](13-syntax.md), or that a
rule calls a parse error, is a parse error, `parse`: in
[Lexical structure](01-lexical.md),
[Operator application](02-expressions.md#operator-application),
[Section](02-expressions.md#section) and
[Do expression](02-expressions.md#do-expression).

## Static errors

| Code | Rule |
|---|---|
| `ambiguous-constraint` | [Generalisation](05-declarations.md#generalisation), [Generalisation](06-static-semantics.md#generalisation), [Ambiguity](06-static-semantics.md#ambiguity) |
| `ambiguous-module` | [The library](07-modules.md#the-library) |
| `ambiguous-name` | [Name resolution](07-modules.md#name-resolution) |
| `arity-mismatch` | [Function binding](05-declarations.md#function-binding) |
| `conflicting-export` | [Exports](07-modules.md#exports) |
| `cyclic-alias` | [Type synonym](05-declarations.md#type-synonym) |
| `cyclic-synonym` | [Pattern synonym](05-declarations.md#pattern-synonym) |
| `duplicate-definition` | [Lambda abstraction](02-expressions.md#lambda-abstraction), [Let expression](02-expressions.md#let-expression), [Record](02-expressions.md#record), [Binders](03-patterns.md#binders), [Records and rows](04-types.md#records-and-rows), [Class](05-declarations.md#class), [Instance](05-declarations.md#instance), [Function binding](05-declarations.md#function-binding) |
| `duplicate-instance` | [Instance](05-declarations.md#instance) |
| `duplicate-signature` | [Type signature](05-declarations.md#type-signature) |
| `grammar-mismatch` | [Grammars](07-modules.md#grammars) |
| `invalid-class` | [Classes over rows](04-types.md#classes-over-rows), [Class](05-declarations.md#class) |
| `invalid-deriving` | [Deriving](05-declarations.md#deriving) |
| `invalid-instance` | [Class](05-declarations.md#class), [Instance](05-declarations.md#instance) |
| `invalid-regex` | [Literals](01-lexical.md#literals), [Regex](11-library.md#regex) |
| `invalid-rule` | [The optimiser](12-core.md#the-optimiser) |
| `invalid-synonym` | [Pattern synonym](05-declarations.md#pattern-synonym) |
| `kind-mismatch` | [Kinds](04-types.md#kinds), [Instance](05-declarations.md#instance) |
| `missing-main` | [The entry point](08-programs.md#the-entry-point) |
| `module-name-mismatch` | [Grammar](07-modules.md#grammar) |
| `non-exhaustive` | [Lambda abstraction](02-expressions.md#lambda-abstraction), [Case expression](02-expressions.md#case-expression), [Let expression](02-expressions.md#let-expression), [Coverage](03-patterns.md#coverage), [Function binding](05-declarations.md#function-binding), [Runtime errors](10-evaluation.md#runtime-errors) |
| `orphan-instance` | [Instance](05-declarations.md#instance) |
| `orphan-signature` | [Type signature](05-declarations.md#type-signature) |
| `redundant-alternative` | [Case expression](02-expressions.md#case-expression), [Coverage](03-patterns.md#coverage) |
| `signature-mismatch` | [Errors](06-static-semantics.md#errors) |
| `type-mismatch` | [Typing](03-patterns.md#typing), [Errors](06-static-semantics.md#errors) |
| `unknown-field` | [Fields](09-tree.md#fields) |
| `unknown-kind` | [Kinds](09-tree.md#kinds) |
| `unresolved-module` | [Grammar](07-modules.md#grammar) |
| `unresolved-name` | [Datatype](05-declarations.md#datatype), [Pattern synonym](05-declarations.md#pattern-synonym), [Name resolution](07-modules.md#name-resolution), [The library](07-modules.md#the-library) |
| `unsatisfied-constraint` | [Errors](06-static-semantics.md#errors) |
| `unsaturated-synonym` | [Type synonym](05-declarations.md#type-synonym), [Pattern synonym](05-declarations.md#pattern-synonym) |

## Runtime errors

`cyclic-value`, `memory-limit` and `int-out-of-range` are in
[Runtime errors](10-evaluation.md#runtime-errors).
