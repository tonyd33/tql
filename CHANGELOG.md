# Changelog

## 0.4.0 (unreleased)

### Breaking Changes

- A declared `type` no longer has `Eq` implicitly. Comparing its values with `=` or `!=` is now an `unsatisfied-constraint` error until the type adds `deriving (Eq)`.

### New Features

- Added `deriving (Eq, Ord, Serial)` on `type` declarations. A derived `Ord` orders by constructor declaration order, then fields left to right.
- A declared type deriving `Serial` can be output. Each constructor encodes as `{"tag": "Just", "fields": [1]}`, and a constructor with no fields as `{"tag": "Nothing", "fields": []}`.
- `Bool` and lists now have `Ord`: `false < true`, and lists compare element by element with a prefix first.

### Bug Fixes

- Fixed `=` on a declared type holding a function, such as `type F = F (Int -> Int)`, which type-checked and failed at runtime with `error: TypeError`. It is now a compile error.

## 0.3.1 (unreleased)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.
