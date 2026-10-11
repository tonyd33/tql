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
- Equality is `==`: write `a == b` and `(== 1)` for `a = b` and `(= 1)`. `=` in an expression is a syntax error. `!=` is unchanged.
- `kind` returns a `Kind`, not a `String`: write `kind n == :comment` for `kind n = "comment"`, and `kind_name n` where a string is needed, such as an anonymous token's spelling. A kind compared this way is checked against the grammar.
- `_ <- e` no longer puts `_` in scope.
- A variable inside a `case` pattern may not shadow a local: in `f x xs = case xs of { [x] -> x; _ -> 0; };` the `x` in `[x]` is a `shadowed-local` error. A variable naming the whole value, as in `case e of { x -> x; }`, still may.
- A declared type no longer has `Eq` implicitly. Add `deriving (Eq)`: `data Shape = Circle Int deriving (Eq);`.
- `%` is no longer an operator. Write ``a `mod` b`` or `mod a b` for `a % b`. `mod` takes the divisor's sign: `mod (-7) 3` is `2`, where `-7 % 3` was `-1`.
- `/` is no longer an operator. Write ``a `div` b``, which floors, or ``a `quot` b``, which truncates as `/` did, with `import Data.Int (div, quot);`.
- Division never fails: `div a 0` and `quot a 0` are `0`, and `mod a 0` and `rem a 0` are `a`, so a query no longer stops with `DivideByZero`.
- The prelude no longer exports the list, function and integer helpers. Import them: `import Data.List (take);` for `filter`, `take`, `drop`, `tail` and `init`; `import Data.Foldable (any);` for `null`, `any`, `all`, `concat` and `concat_map`; `import Data.Function (const);` for `const` and `flip`; `import Data.Int (mod);` for `mod`, `subtract` and `toint`; `import Control.Monad (kleisli);` for `kleisli`. Operators and `do` still work without an import.
- The compile stats report `library_ns` in place of `prelude_ns`.
- A type given the wrong number of arguments, a row variable used as a type, and a type used as a row are `kind-mismatch` errors, not `type-mismatch`: `Maybe` has kind `Type -> Type`, and only a type of kind `Type` has values.
- `append` is the `Semigroup` method, exported by the prelude. Drop it from `import Data.List (...)`.
- `Unit` is replaced by `()`, the empty tuple: write `()` for the value, the pattern and the type. `guard` returns `f ()`, and the `Data.Unit` module is gone.
- The filter `first` is removed, so `Arrow` can take the name. A step after `|` runs once per result, so a filter's first result is a list function composed after it: write `Filter (take 1 . run p)` for `first p`, and `take 1 $ run p x` for `first p x`, with `import Data.List (take);`. `head . run p` gives the first result as a `Maybe`.
- `head`, `tail` and the new `last` and `init` return a `Maybe`: `head [] = Nothing`, `tail [1, 2] = Just [2]`. Write `take 1 xs` and `drop 1 xs` for the old list results.
- `Filter a b` is a `newtype` over `a -> [b]`, and a filter is no longer a function. Apply one with `run p x`, and make one from a function with `Filter (\x -> ...)`. The axes, `of_kind`, `filename`, `toint` and `#f` are filters; `x#f` is still the list of `x`'s children in field `f`.
- `main` is a `Filter Node t`. `main root = do { x <- descendants root; ... };` becomes `main = do { x <- descendants; ... };`: a `do` over `Filter Node` gives every statement the root, `root <- identity;` names it, and `y <- pure x | p;` binds `p`'s results at `x`. `main root = [v];` becomes `main = pure v;`, and a signature `main :: Node -> [Int]` becomes `main :: Filter Node Int`.
- `|` composes left to right in any `Category`, so both sides are filters: a lambda after `|` is written `Filter (\x -> ...)`. `<|>` is `Alternative`'s `alt`.
- `none` is removed: write `empty`. `collect`, `keep`, `has` and `or_else` take filters.
- A `String` is always UTF-8 text. `text` and `filename` replace each ill-formed byte sequence with U+FFFD, so a Latin-1 file's text outputs as a JSON string, not an array of bytes; `range` still gives the source bytes. `length` of a string counts code points: `length "héllo"` is 5, not 6. A string literal that is not UTF-8 is a parse error.
- `_` is a wildcard in every binding position and never a value: `\_ _ -> 1`, `h _ _ = 1` and `let { _ = e; }` bind nothing, and `_` as an expression is a parse error. `\_ -> _` returned its argument.
- A name bound twice in one `let` group, one lambda or one definition's parameters is a `duplicate-definition` error: `\x x -> x` and `let { y = 5; y = 6; }` took the last binder. A nested lambda or a later `do` bind may still shadow.
- A regex reads UTF-8 code points: `.` matches `é`, and an ill-formed byte sequence in the subject reads as U+FFFD. `\d`, `\w` and `\s` stay ASCII, and `(?i)` folds case beyond ASCII. The syntax is PCRE2's, without backreferences, which are now an `invalid-regex` error, or `\C`. `\K` and backtracking verbs such as `(*PRUNE)` stop the run with `RegexFailed`.
- `tql query` warns about a target file that does not parse under the grammar, and exits 2 when no file failed outright. Findings from such a file come from tree-sitter's error recovery and may be incomplete. `--format=json` lists each file's `syntax_errors`, an `ERROR` node or a token recovery inserted, with its location.

### New Features

- Added `f . g` for function composition.
- Added `a >> b` for sequencing, as a `do` expression statement.
- Added list patterns `[]` and `[a, b]`, and cons `h : t` in patterns and expressions. `x:xs` is cons; `:k` after whitespace is still a kind.
- Added record field access: `r.start_byte` reads a field, and `_.start_byte` is the function that does. `(range a).start_byte < (range b).start_byte` compares document order.
- Added open record types to signatures: `{name: String | r}` is any record with a `name` field.
- Added type aliases: `type Named r = {name: String | r};`. `Range` and `Point` are aliases now.
- Added backtick infix application: ``8 `mod` 5`` is `mod 8 5`, and ``a `Pair` b`` is `Pair a b`.
- Added operator sections: `(== 1)` is `\x -> x == 1`, `(10 -)` is `\y -> 10 - y`, and `(+)` is `\x y -> x + y`.
- Added `subtract`.
- Added `div`, `quot` and `rem` to `Data.Int`. `div` and `mod` floor, `quot` and `rem` truncate, and each pair satisfies `q * b + r == a` for every `a` and `b`.
- A query may define a name or declare a type the prelude has.
- Added modules: `module A.B (x, T(..));` names a module and its exports, and `import A.B;`, `import A.B (x);`, `import A.B hiding (x);` and `import A.B as Q;` bring them into scope. `Q.x` names an export of the import qualified as `Q`. `import Prelude hiding (x);` replaces the implicit prelude import.
- `tql query` finds `import A.B` as `A/B.tql` in the query file's directory, then each `-I dir`, then each directory in `TQL_PATH`.
- `module A.B for javascript, typescript;` declares the grammars a module reads. Importing it under another grammar is an error, and an imported module without `for` may not use grammar-specific syntax like kinds or fields.
- `tql-js` `query` takes `modules`, a record of module name to source.
- The built-in types `Int`, `String`, `Regex`, `Node`, `Kind`, `Range` and `Point` are prelude exports: `import Prelude hiding (Int)` and `P.Int` work, and a module may declare its own `Int`.
- Added `kind_name :: Node -> String`, a node's kind as a string. An anonymous token's is its spelling.
- Added `is_extra :: Node -> Bool`, true for a grammar's extras such as comments: `named_children | keep (not . is_extra)` drops comments.
- A function with a signature may call itself at another type: `nest :: Int -> a -> Int; nest n x = if n == 0 then 0 else 1 + nest (n - 1) [x];`.
- Kinds compare with `==` and `!=`, and a `Kind` outputs as its name: `main = pure :comment;` yields `["comment"]`.
- `do` binds take the same patterns as `case`: `[a, b] <- xs;` binds each two-element list in `xs` and skips the others.
- Added view patterns: `(e -> p)` matches `p` against `e` applied to the value, so `(#decorator -> [])` matches a node with no decorator. A view may use variables bound to its left in the same pattern.
- Added as-patterns `x@p` and conjunctions `p & q`, which match both sides against one value.
- Added literal patterns: a number, string, `true`, `false` or kind `:k` matches a value equal to it, and a regex `r"..."` matches a string it matches. `case kind n of { :class_declaration -> 1; _ -> 0; }` dispatches on a node's kind.
- Added guards to `case` alternatives: in `[a, b] if a == b -> 1`, a false guard tries the alternatives after it.
- Added node patterns: `:k { #f = p }` matches a node of kind `k` whose field `f` holds one node matching `p`, `:k {}` matches any node of kind `k`, and `{ #f = p }` any node with the field. `call@:call_expression { #function = :member_expression {} } <- descendants;` binds each method call.
- Added classes and instances: `class Eq a => Describe a where { describe :: a -> String; };`.
- Classes share the type namespace: `C(..)` in an export or import list brings a class's methods, `C` alone brings only the class, and a method may be listed alone as a value.
- `Eq`, `Ord` and `Sized` are prelude classes: `class Eq a where { eq :: a -> a -> Bool; };`, `class Eq a => Ord a where { compare :: a -> a -> Ordering; };` and `class Sized a where { length :: a -> Int; };`. A written instance is what `==`, `<` and `length` call at its type: `instance Eq Name where { eq a b = ...; };`. `!=` is `not (eq a b)` and `<`, `<=`, `>`, `>=` are read off `compare`. Known types compile to the same comparisons as before.
- Added `deriving (Eq, Ord, Serial)` on a `data` declaration.
- A declared type that derives `Serial` outputs as JSON, every constructor as `{"tag": "Just", "fields": [1]}` and a nullary one as `{"tag": "Nothing", "fields": []}`.
- Added `Ordering`, with `LT`, `EQ` and `GT`, and `Ord` on `Bool` and lists: `False < True`, and lists compare lexicographically, `[1] < [1, 0]`.
- Every primitive is a `Prim` definition with a signature, such as `text :: Node -> String; text = %text;`. A primitive's `%` name resolves in any module, and `data X = %Int;` is accepted only for the built-in types.
- Added `seq :: a -> b -> b`, which evaluates its first argument before returning its second.
- `module M` in an export list re-exports what the module imports from `M`, and an export list may name an imported value or type.
- `T(..)` in an import list is accepted for a type with no constructors, such as `Int`, whatever the export list says.
- A type variable may be applied to types, and a declared type may be left short of its last arguments: `data Wrap f a = Wrap (f a);` holds a `Wrap Maybe Int` or a `Wrap (Either String) Int`. Kinds are inferred.
- An alias parameter its body never uses is no longer an error.
- A class may range over type constructors: `class Mappable f where { mapf :: (a -> b) -> f a -> f b; };` takes `instance Mappable List` and `instance Mappable (Either e)`. A context may constrain an applied variable, `Eq (f a) =>`, and one is inferred where needed.
- A type variable applied to an argument matches a function type: `f a` against `Int -> Bool` makes `f` the function type short of its result, printed `(->) Int`.
- Added the `Functor` class, whose method is `map`.
- Added the `Applicative` class, with `pure :: a -> f a` and `ap :: f (a -> b) -> f a -> f b`. `return` is `pure`.
- Added the `Alternative` class, with `empty :: f a` and `alt :: f a -> f a -> f a`. `guard` and `<|>` work at any `Alternative`, not only lists.
- A type constructor variable that nothing determines is a list when a list satisfies its constraints: `count x = length (pure x)` is `a -> Int`.
- Added the `Semigroup` and `Monoid` classes, with `append :: a -> a -> a` and `mempty :: a`, at lists, `Unit` and `Ordering`.
- Added the `Foldable` class, whose method is `foldr`, and `fold_map`, `fold` and `to_list` in `Data.Foldable`. `null`, `any`, `all` and `concat` work at any `Foldable`, not only lists.
- Added the `Traversable` class, whose method is `traverse`, and `sequence`: `sequence [[1, 2], [3, 4]]` is `[[1, 3], [1, 4], [2, 3], [2, 4]]`.
- Added `Data.Maybe`: `import Data.Maybe (Maybe(..));` brings `Maybe`, `Nothing` and `Just`, a `Functor`, `Applicative`, `Alternative`, `Foldable`, `Traversable` and `Monad`.
- Added the `Monad` class, whose method is `bind`, and `join`, `kleisli` and `mfilter` in `Control.Monad`.
- `do` and `>>` run in any `Monad`: `both m n = do { a <- m; b <- n; return (a + b); };` works at `Maybe`. A pattern that may not match falls through to `empty`, so it needs an `Alternative`. A block over lists compiles as before.
- Added tuples: `(1, "a")` is a value, `(n, s)` a pattern and `(Int, String)` a type, with up to 255 components. `(,)` and `(,,)` are their constructors as functions.
- Added `newtype`: `newtype Name = Name String;` declares a type distinct from `String` to the type checker.
- Added `Control.Category`, with the `Category` class (`identity`, `compose`), and `Control.Arrow`, with `newtype Kleisli m a b = Kleisli (a -> m b)` and `run_kleisli`. `Kleisli m a` is a `Functor`, `Applicative`, `Alternative` and `Monad` that gives every step the same input, and `Kleisli m` a `Category`, so `|` composes `Kleisli` arrows.
- `identity` and `compose` are `Category`'s methods, with an instance at functions, and the prelude exports them. `.` is `compose`, so it composes `Kleisli` arrows as well as functions.
- Added `Arrow` (`arr`, `first`, `second`, `split`, `fanout`), `ArrowZero` (`zero_arrow`) and `ArrowPlus` (`plus`) to `Control.Arrow`, with instances at functions and at `Kleisli m`.
- `(->)` is the function type's constructor in types: `instance Mappable ((->) r)` is an instance at functions from `r`. An instance head may also be a function type over two variables: `instance Combine b => Combine (a -> b)`.
- The prelude exports `Maybe(..)`, `head` and `last`.
- `Filter` is a `Functor`, `Applicative`, `Alternative` and `Monad` in its output, and a `Category`, `Arrow`, `ArrowZero` and `ArrowPlus`, as `Kleisli List` is. `arr` is `Arrow`'s method, and the prelude exports `Control.Arrow`, `Filter(..)` and `run`.

### Improvements

- A record literal with more fields than a type can index is reported at the literal. It was previously reported with no location.
- A type variable in an alias body that is not one of the alias's parameters is reported at the variable, not the whole body.
- `Int String` reports that `Int` takes no type arguments. It was reported as `Int` not being a type.
- Queries are simplified before they run: a binding used once moves to its use, a small function applied to all its arguments is inlined, and a `case` of a known constructor takes its alternative.
- A `do` bind over `children`, `named_children`, `descendants` or `named_descendants` whose pattern tests a kind, such as `:k { .. }` or `(of_kind :k -> [n])`, walks only nodes of that kind, as `descendants_of_kind :k` does.
- A query that allocates more than 4 GiB on one file stops on that file with `OutOfMemory`, and the run continues with the next. Such a query could exhaust the machine's memory.
- The library is compiled once per engine, and once per loaded wasm module in `tql-js` and the playground: compiling a later query starts from it.
- A constraint `main` cannot satisfy is reported where it is raised: in `main = arr (\x -> x < x);` the `Ord Node` error points at `x < x`.
- A function given only some of its arguments is inlined when one of them is a constructor, a lambda or a class dictionary: `main = pure 1` compiles to `\x -> [1]`.
- A function given every argument its type takes is inlined although its body takes more, as `keep is_named` builds a `Filter` from one argument: `descendants | keep is_named` compiles to one loop.
- A `do` bind over a one-element list is the rest of the block applied to the element: `y <- pure x | p;` costs what `y <- run p x;` does.
- A function passed a named recursive function is inlined as if passed a lambda: `concat` over lists compiles to a loop calling `append`.
- A function every call passes the same class instance takes that instance in place of a dictionary parameter, so its methods are selected at compile time: `any` over lists compiles to a loop, and a local function using `length` calls the list's `length` directly.

### Bug Fixes

- A regex match never gives up: `~` no longer reads a pattern that backtracks too much as no match, nor `!~` as a match.
- `Int` arithmetic wraps in every build mode: `9223372036854775807 + 1` is `-9223372036854775808`. It panicked in a debug build, and the least `Int` divided by `-1` killed the process.
- A signature types every use of its definition, including from the definitions it calls: with `a :: Node -> [String]; a x = b x; b x = a x;`, `b` is `Node -> [String]`.
- A function bound in a `let` group can be used at different types by the other bindings in the group: `let { me x = x; a = me 1; b = me "s"; }` type-checks.
- `children_of_kind` and `descendants_of_kind` given an anonymous token's kind, such as `kind open` for a `(`, yield those tokens. They yielded nothing, and so did `descendants root | of_kind (kind open)`.
- `main`'s constraints are checked at the type it runs at: `main = arr (\x -> x < x);` is an `unsatisfied-constraint` error, since `Node` has no `Ord`. It was accepted.
- `==` on a declared type holding a function, as in `data F = F (Int -> Int);`, is a compile error. It failed with `TypeError` when it ran.
- A record literal that repeats a label, as in `{a = 1, a = "x"}`, is a `duplicate-definition` error.
- The empty record `{}` can be used as a value: `main = pure {};` gives `[{}]`. It failed with `Unsupported`.
- An unsatisfied constraint names its type variables as a type mismatch does: `` `Eq (a -> a)` is not satisfied``.

## 0.3.1 (2026-10-03)

### New Features

- Added `tql inspect` for seeing tree shapes while writing queries.

### Improvements

- `tql-js`'s `parseTree` rows now carry `isError`, and `text` on nodes with no children.

### Bug Fixes

- A constructor applied to fewer than all its fields, as in `map (Pair 1) xs` or `flip Pair 1 2`, no longer fails with `error.Unsupported`.
