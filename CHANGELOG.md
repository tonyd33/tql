# Changelog

## 0.4.0 (unreleased)

### Breaking Changes

- A bare `.` is no longer the identity filter; write `arr identity`.
- Signatures are written `f :: T`, and inferred types print that way.
- `children` and `descendants` also yield anonymous tokens, such as the `type` in `import type`. `named_children` and `named_descendants` keep the old behaviour.
- Grammar fields are read with `#`. `.` now reads record fields.
- `range` returns a record.
- `<|>` binds tighter than `|`: `a <|> b | f` is `(a <|> b) | f`.
- Datatypes are declared with `data`: `data Bool = False | True;`.
- `kind` returns a `Kind`, not a `String`: write `kind n = :comment` for `kind n = "comment"`, and `kind_name n` where a string is needed, such as an anonymous token's spelling. A kind compared this way is checked against the grammar.

### New Features

- Added `f . g` for function composition.
- Added `a >> b` for sequencing, as a `do` expression statement.
- Added list patterns `[]` and `[a, b]`, and cons `h : t` in patterns and expressions. `x:xs` is cons; `:k` after whitespace is still a kind.
- Added record field access: `r.start_byte` reads a field, and `_.start_byte` is the function that does. `(range a).start_byte < (range b).start_byte` compares document order.
- Added open record types to signatures: `{name: String | r}` is any record with a `name` field.
- Added type aliases: `type Named r = {name: String | r};`. `Range` and `Point` are aliases now.
- Added backtick infix application: ``8 `mod` 5`` is `mod 8 5`, and ``a `Pair` b`` is `Pair a b`.
- Added operator sections: `(= 1)` is `\x -> x = 1`, `(10 -)` is `\y -> 10 - y`, and `(+)` is `\x y -> x + y`.
- Added `subtract`.
- A query may define a name or declare a type the prelude has.
- Added modules: `module A.B (x, T(..));` names a module and its exports, and `import A.B;`, `import A.B (x);`, `import A.B hiding (x);` and `import A.B as Q;` bring them into scope. `Q.x` names an export of the import qualified as `Q`. `import Prelude hiding (x);` replaces the implicit prelude import.
- `tql query` finds `import A.B` as `A/B.tql` in the query file's directory, then each `-I dir`, then each directory in `TQL_PATH`.
- `module A.B for javascript, typescript;` declares the grammars a module reads. Importing it under another grammar is an error, and an imported module without `for` may not use grammar-specific syntax like kinds or fields.
- `tql-js` `query` takes `modules`, a record of module name to source.
- The built-in types `Int`, `String`, `Regex`, `Node`, `Kind`, `Range` and `Point` are prelude exports: `import Prelude hiding (Int)` and `P.Int` work, and a module may declare its own `Int`.
- Added `kind_name :: Node -> String`, a node's kind as a string. An anonymous token's is its spelling.
- Added `is_extra :: Node -> Bool`, true for a grammar's extras such as comments: `named_children | keep (not . is_extra)` drops comments.
- A function with a signature may call itself at another type: `nest :: Int -> a -> Int; nest n x = if n = 0 then 0 else 1 + nest (n - 1) [x];`.
- Kinds compare with `=` and `!=`, and a `Kind` outputs as its name: `main = pure :comment;` yields `["comment"]`.

### Improvements

- A record literal with more fields than a type can index is reported at the literal. It was previously reported with no location.
- A type variable in an alias body that is not one of the alias's parameters is reported at the variable, not the whole body.
- `Int String` reports that `Int` takes no type arguments. It was reported as `Int` not being a type.
- Queries are simplified before they run: a binding used once moves to its use, a small function applied to all its arguments is inlined, and a `case` of a known constructor takes its alternative.

### Bug Fixes

- A signature types every use of its definition, including from the definitions it calls: with `a :: Node -> [String]; a x = b x; b x = a x;`, `b` is `Node -> [String]`.
- A function bound in a `let` group can be used at different types by the other bindings in the group: `let { me x = x; a = me 1; b = me "s"; }` type-checks.
- `children_of_kind` and `descendants_of_kind` given an anonymous token's kind, such as `kind open` for a `(`, yield those tokens. They yielded nothing, and so did `descendants root | of_kind (kind open)`.

## 0.3.1 (2026-10-03)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.

### Bug Fixes

- A constructor applied to fewer than all its fields, as in `map (Pair 1) xs` or `flip Pair 1 2`, no longer fails with `error.Unsupported`.
