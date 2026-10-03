# Changelog

## 0.4.0 (unreleased)

### Breaking Changes

- A bare `.` is no longer the identity filter; write `arr identity`.
- Signatures are written `f :: T`, and inferred types print that way.
- `children` and `descendants` also yield anonymous tokens, such as the `type` in `import type`. `named_children` and `named_descendants` keep the old behaviour.
- Grammar fields are read with `#`. `.` now reads record fields.
- `range` returns a record.
- `<|>` binds tighter than `|`: `a <|> b | f` is `(a <|> b) | f`.

### New Features

- Added `f . g` for function composition.
- Added `a >> b` for sequencing, as a `do` expression statement.
- Added list patterns `[]` and `[a, b]`, and cons `h : t` in patterns and expressions. `x:xs` is cons; `:k` after whitespace is still a kind.
- Added record field access: `r.start_byte` reads a field, and `_.start_byte` is the function that does. `(range a).start_byte < (range b).start_byte` compares document order.
- Added open record types to signatures: `{name: String | r}` is any record with a `name` field.
- Added backtick infix application: ``8 `mod` 5`` is `mod 8 5`, and ``a `Pair` b`` is `Pair a b`.

## 0.3.1 (unreleased)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.

### Bug Fixes

- A constructor applied to fewer than all its fields, as in `map (Pair 1) xs` or `flip Pair 1 2`, no longer fails with `error.Unsupported`.
