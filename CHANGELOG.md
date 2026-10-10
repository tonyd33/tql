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
- `_ <- e` no longer puts `_` in scope.
- A variable inside a `case` pattern may not shadow a local: in `f x xs = case xs of { [x] -> x; _ -> 0; };` the `x` in `[x]` is a `shadowed-local` error. A variable naming the whole value, as in `case e of { x -> x; }`, still may.
- A declared type no longer has `Eq` implicitly. Add `deriving (Eq)`: `data Shape = Circle Int deriving (Eq);`.
- `%` is no longer an operator. Write ``a `mod` b`` or `mod a b` for `a % b`. `mod` takes the divisor's sign: `mod (-7) 3` is `2`, where `-7 % 3` was `-1`.
- The prelude no longer exports the list, function and integer helpers. Import them: `import Data.List (map, any);` for `map`, `filter`, `foldr`, `append`, `concat`, `concat_map`, `null`, `any`, `all`, `take`, `drop`, `head` and `tail`; `import Data.Function (const);` for `identity`, `const`, `compose` and `flip`; `import Data.Int (mod);` for `mod`, `subtract` and `toint`; `import Data.Filter (alt);` for `kleisli` and `alt`. Operators and `do` still work without an import.
- The compile stats report `library_ns` in place of `prelude_ns`.

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
- `do` binds take the same patterns as `case`: `[a, b] <- xs;` binds each two-element list in `xs` and skips the others.
- Added view patterns: `(e -> p)` matches `p` against `e` applied to the value, so `(#decorator -> [])` matches a node with no decorator. A view may use variables bound to its left in the same pattern.
- Added as-patterns `x@p` and conjunctions `p & q`, which match both sides against one value.
- Added literal patterns: a number, string, `true`, `false` or kind `:k` matches a value equal to it, and a regex `r"..."` matches a string it matches. `case kind n of { :class_declaration -> 1; _ -> 0; }` dispatches on a node's kind.
- Added guards to `case` alternatives: in `[a, b] if a = b -> 1`, a false guard tries the alternatives after it.
- Added node patterns: `:k { #f = p }` matches a node of kind `k` whose field `f` holds one node matching `p`, `:k {}` matches any node of kind `k`, and `{ #f = p }` any node with the field. `call@:call_expression { #function = :member_expression {} } <- descendants root;` binds each method call.
- Added classes and instances: `class Eq a => Describe a where { describe :: a -> String; };`.
- Classes share the type namespace: `C(..)` in an export or import list brings a class's methods, `C` alone brings only the class, and a method may be listed alone as a value.
- `Eq`, `Ord` and `Sized` are prelude classes: `class Eq a where { eq :: a -> a -> Bool; };`, `class Eq a => Ord a where { compare :: a -> a -> Ordering; };` and `class Sized a where { length :: a -> Int; };`. A written instance is what `=`, `<` and `length` call at its type: `instance Eq Name where { eq a b = ...; };`. `!=` is `not (eq a b)` and `<`, `<=`, `>`, `>=` are read off `compare`. Known types compile to the same comparisons as before.
- Added `deriving (Eq, Ord, Serial)` on a `data` declaration.
- A declared type that derives `Serial` outputs as JSON, every constructor as `{"tag": "Just", "fields": [1]}` and a nullary one as `{"tag": "Nothing", "fields": []}`.
- Added `Ordering`, with `LT`, `EQ` and `GT`, and `Ord` on `Bool` and lists: `False < True`, and lists compare lexicographically, `[1] < [1, 0]`.
- Every primitive is a `Prim` definition with a signature, such as `text :: Node -> String; text = %text;`. A primitive's `%` name resolves in any module, and `data X = %Int;` is accepted only for the built-in types.
- Added `seq :: a -> b -> b`, which evaluates its first argument before returning its second.
- `module M` in an export list re-exports what the module imports from `M`, and an export list may name an imported value or type.
- `T(..)` in an import list is accepted for a type with no constructors, such as `Int`, whatever the export list says.

### Improvements

- A record literal with more fields than a type can index is reported at the literal. It was previously reported with no location.
- A type variable in an alias body that is not one of the alias's parameters is reported at the variable, not the whole body.
- `Int String` reports that `Int` takes no type arguments. It was reported as `Int` not being a type.
- Queries are simplified before they run: a binding used once moves to its use, a small function applied to all its arguments is inlined, and a `case` of a known constructor takes its alternative.
- A `do` bind over `children`, `named_children`, `descendants` or `named_descendants` whose pattern tests a kind, such as `:k { .. }` or `(of_kind :k -> [n])`, walks only nodes of that kind, as `descendants_of_kind :k` does.
- A query that allocates more than 4 GiB on one file stops on that file with `OutOfMemory`, and the run continues with the next. Such a query could exhaust the machine's memory.
- The library is compiled once per engine, and once per loaded wasm module in `tql-js` and the playground: compiling a later query starts from it.

### Bug Fixes

- A signature types every use of its definition, including from the definitions it calls: with `a :: Node -> [String]; a x = b x; b x = a x;`, `b` is `Node -> [String]`.
- A function bound in a `let` group can be used at different types by the other bindings in the group: `let { me x = x; a = me 1; b = me "s"; }` type-checks.
- `children_of_kind` and `descendants_of_kind` given an anonymous token's kind, such as `kind open` for a `(`, yield those tokens. They yielded nothing, and so did `descendants root | of_kind (kind open)`.
- `main`'s constraints are checked at the type it runs at: `main x = [x < x];` is an `unsatisfied-constraint` error, since `Node` has no `Ord`. It was accepted.
- `=` on a declared type holding a function, as in `data F = F (Int -> Int);`, is a compile error. It failed with `TypeError` when it ran.
- The empty record `{}` can be used as a value: `main = const [{}];` gives `[{}]`. It failed with `Unsupported`.
- An unsatisfied constraint names its type variables as a type mismatch does: `` `Eq (a -> a)` is not satisfied``.

## 0.3.1 (2026-10-03)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.

### Bug Fixes

- A constructor applied to fewer than all its fields, as in `map (Pair 1) xs` or `flip Pair 1 2`, no longer fails with `error.Unsupported`.
