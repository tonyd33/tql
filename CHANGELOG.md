# Changelog

## 0.4.0 (unreleased)

### Breaking Changes

- A bare `.` is no longer the identity filter; write `arr identity`.

### New Features

- Added `f . g` for function composition.

## 0.3.1 (unreleased)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.
