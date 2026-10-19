# Predefined types and classes

This chapter gives the standard types, their operations, and each class
with its laws and the library's instances of it. A law is an equation between meanings, `⊥` included, that every
instance must satisfy. The library and the [optimiser](12-core.md)
rely on the laws: an instance that breaks one gets results they do not
predict.

## Modules

| Module | Contents |
|---|---|
| `Prim` | primitive types and operations |
| `Prelude` | the common names below, imported implicitly |
| `Data.Bool` | `not`, `&&`, `\|\|`, `and`, `or` |
| `Data.Int` | `+`, `-`, `*`, `div`, `mod`, `quot`, `rem`, `subtract`, `toint` |
| `Data.Ord` | `Ord` and its functions |
| `Data.List` | list functions, `foldl'`, `Sized` |
| `Data.Maybe` | `Maybe` functions |
| `Data.Tuple` | `fst`, `snd`, `swap` |
| `Data.Function` | `$`; `identity` and `.`, re-exported from `Control.Category` |
| `Data.Regex` | `~`, `!~` |
| `Data.Functor` | `Functor` |
| `Data.Foldable` | `Foldable` and its functions |
| `Data.Traversable` | `Traversable`, `sequence` |
| `Data.Monoid` | `Semigroup`, `Monoid` |
| `Data.Filter` | `Filter`, `run`, `collect`, `keep`, `has`, `or_else` |
| `Data.Node` | the tree operations and axes |
| `Control.Category` | `Category`, `.`, `\|` |
| `Control.Arrow` | `Arrow`, `ArrowZero`, `ArrowPlus`, `Kleisli` |
| `Control.Applicative` | `Applicative`, `Alternative`, `<\|>`, `guard` |
| `Control.Monad` | `Monad`, `>>`, `join`, `kleisli`, `mfilter` |

## Standard types

| Type | Values |
|---|---|
| `Int` | 64-bit two's complement integers |
| `String` | well-formed UTF-8 text |
| `Regex` | compiled regular expressions; only literals |
| `Node` | nodes of a target file's syntax tree ([The tree](09-tree.md)) |
| `Kind` | node kinds of the target grammar ([Kinds](09-tree.md#kinds)) |
| `Bool` | `False`, `True` |
| `Ordering` | `LT`, `EQ`, `GT` |
| `List a` | `Nil`, `Cons a (List a)` |
| `Maybe a` | `Nothing`, `Just a` |
| `(a1, ..., an)` | tuples of n components, n = 0 or 2 ≤ n ≤ 255; `()` is the unit |
| `Json` | `JNull`, `JBool Bool`, `JNumber Int`, `JString String`, `JArray [Json]`, `JObject [(String, Json)]` |

There is no character type.

```tql
fst :: (a, b) -> a;
fst p = case p of { (a, _) -> a; };

snd :: (a, b) -> b;
snd p = case p of { (_, b) -> b; };

swap :: (a, b) -> (b, a);
swap p = (snd p, fst p);
```

`swap` takes its pair lazily.

## Int

`Int` is 64-bit two's complement. Every operation is total:

- `+`, `-` and `*` wrap: `9223372036854775807 + 1` is
  `-9223372036854775808`.
- `div` and `mod` round the quotient toward negative infinity; `quot` and
  `rem` round it toward zero. `mod (-7) 3` is `2`; `rem (-7) 3` is `-1`.
- A zero divisor gives quotient `0` and remainder the dividend: `div 7 0`
  is `0` and `mod 7 0` is `7`.
- The least `Int` divided by `-1` wraps to itself, with remainder `0`.

So `q * b + r == a` holds for every `a` and `b`, for each pair.

`toint :: String -> Maybe Int` reads decimal digits with an optional
leading `-`, and gives `Nothing` for anything else or a number out of
range.

## String

A `String` is well-formed UTF-8 text, not a list. Text read from outside
the program, a node's source or a file name, is decoded with each maximal
ill-formed subsequence replaced by U+FFFD.

## Regex

```tql
(~) :: String -> Regex -> Bool;
(!~) :: String -> Regex -> Bool;
```

`s ~ re` holds when `re` matches somewhere in `s`, and `s !~ re` when it
does not. Matching takes time linear in the length of `s`, for every
pattern, and never fails.

The dialect:

- matches over code points;
- `\d`, `\w` and `\s` are ASCII;
- `(?i)` folds case;
- has no backreferences, lookaround, recursion, possessive quantifiers,
  atomic groups or backtracking verbs.

A pattern outside the dialect is an error, `invalid-regex`.

## Eq and Ord

```tql
class Eq a where {
  (==) :: a -> a -> Bool;
  (!=) :: a -> a -> Bool;
  x == y = not (x != y);
  x != y = not (x == y);
  minimal (==) | (!=);
  deriving %derive_eq;
};

class Eq a => Ord a where {
  compare :: a -> a -> Ordering;
  (<) :: a -> a -> Bool;
  (<=) :: a -> a -> Bool;
  (>) :: a -> a -> Bool;
  (>=) :: a -> a -> Bool;
  max :: a -> a -> a;
  min :: a -> a -> a;
  compare x y = if x == y then EQ else if x <= y then LT else GT;
  x <= y = compare x y != GT;
  x < y = compare x y == LT;
  x > y = compare x y == GT;
  x >= y = compare x y != LT;
  max x y = if x <= y then y else x;
  min x y = if x <= y then x else y;
  deriving %derive_ord;
  minimal compare | (<=);
};
```

```
x == x                                        reflexivity
x == y  =  y == x                             symmetry
x == y && y == z  ⟹  x == z                   transitivity
x != y  =  not (x == y)

x <= y || y <= x                              totality
x <= y && y <= z  ⟹  x <= z                   transitivity
x <= y && y <= x  ⟹  x == y                   antisymmetry
compare x y == EQ  =  x == y
compare x y == LT  =  compare y x == GT
x < y  =  compare x y == LT     and likewise for <=, >, >=
```

Instances:

```
Eq Int                                    Ord Int
Eq String                                 Ord String
Eq Bool                                   Ord Bool
Eq Ordering                               Ord Ordering
Eq a => Eq [a]                            Ord a => Ord [a]
Eq a => Eq (Maybe a)                      Ord a => Ord (Maybe a)
(Eq a1, ..., Eq an) => Eq (a1, ..., an)   (Ord a1, ..., Ord an) => Ord (a1, ..., an)
All Eq ρ => Eq (Record ρ)                 All Ord ρ => Ord (Record ρ)
Eq Node
Eq Kind
```

`String` is ordered by code point, `Bool` with `False < True`, lists
lexicographically with a prefix first, and `Maybe` with `Nothing` first.
The tuple instances hold for every n, `()` included. Records are in
[Classes over rows](04-types.md#classes-over-rows). No function type has
either class.

## Semigroup and Monoid

```tql
class Semigroup a where {
  append :: a -> a -> a;
};

class Semigroup a => Monoid a where {
  mempty :: a;
};
```

```
append (append x y) z  =  append x (append y z)
append mempty x  =  x  =  append x mempty
```

Instances:

```
Semigroup [a]          Monoid [a]
Semigroup ()           Monoid ()
Semigroup Ordering     Monoid Ordering
```

`append` on lists is concatenation, and on `Ordering` it takes the first
non-`EQ`.

## Functor, Applicative, Monad and Alternative

```tql
class Functor f where {
  map :: (a -> b) -> f a -> f b;
  deriving %derive_functor;
};

class Functor f => Applicative f where {
  pure :: a -> f a;
  ap :: f (a -> b) -> f a -> f b;
};

class Applicative m => Monad m where {
  bind :: m a -> (a -> m b) -> m b;
};

class Applicative f => Alternative f where {
  empty :: f a;
  alt :: f a -> f a -> f a;
};
```

```
map identity  =  identity
map (f . g)  =  map f . map g

ap (pure identity) v  =  v
ap (ap (ap (pure (.)) u) v) w  =  ap u (ap v w)
ap (pure f) (pure x)  =  pure (f x)
ap u (pure y)  =  ap (pure (\f -> f y)) u
map f x  =  ap (pure f) x

bind (pure a) f  =  f a
bind m pure  =  m
bind (bind m f) g  =  bind m (\x -> bind (f x) g)
ap mf mx  =  bind mf (\f -> bind mx (\x -> pure (f x)))

alt empty x  =  x  =  alt x empty
alt (alt x y) z  =  alt x (alt y z)
bind empty f  =  empty
```

The last law is what makes a failing `do` bind
([Do expression](02-expressions.md#do-expression)) mean what it says.

Derived from the methods:

```tql
(<|>) :: Alternative f => f a -> f a -> f a;
x <|> y = alt x y;

(>>) :: Monad m => m a -> m b -> m b;
x >> y = bind x $ \_ -> y;

return :: Applicative f => a -> f a;
return = pure;

guard :: Alternative f => Bool -> f ();
guard b = if b then pure () else empty;

kleisli :: Monad m => (a -> m b) -> (b -> m c) -> a -> m c;
kleisli p q x = bind (p x) q;
```

Instances, for each class `C` of the four:

```
C List
C Maybe
C m => C (Kleisli m a)
```

So `Filter a` has all four. At lists, `ap` is the Cartesian product, function-major,
and `alt` is concatenation. At `Kleisli m a`, every component reads the
same input:

```
run_kleisli (bind k f) x  =  bind (run_kleisli k x) (\y -> run_kleisli (f y) x)
```

## Foldable and Traversable

```tql
class Foldable t where {
  foldr :: (a -> b -> b) -> b -> t a -> b;
  null :: t a -> Bool;
  to_list :: t a -> [a];
  null xs = foldr (\_ _ -> False) True xs;
  to_list xs = foldr Cons Nil xs;
  deriving %derive_foldable;
};

class (Functor t, Foldable t) => Traversable t where {
  traverse :: Applicative f => (a -> f b) -> t a -> f (t b);
  deriving %derive_traversable;
};
```

An instance defines `foldr` and `traverse`; the other methods have
defaults.

```
to_list  =  foldr Cons Nil
null  =  foldr (\_ _ -> False) True
foldr f z . map g  =  foldr (f . g) z
traverse pure  =  pure
```

Instances:

```
Foldable List      Traversable List
Foldable Maybe     Traversable Maybe
```

The folds over them are lazy in the accumulator, so `any`, `all` and
`null` stop at the first element that decides them. The left fold is
`foldl'`, strict in its accumulator; there is no lazy `foldl`.

## Sized

```tql
class Sized a where {
  length :: a -> Int;
};
```

Instances:

```
Sized [a]
Sized String
```

`String` counts code points.

## Category and Arrow

```tql
class Category k where {
  identity :: k a a;
  compose :: k b c -> k a b -> k a c;
};

class Category k => Arrow k where {
  arr :: (a -> b) -> k a b;
  first :: k a b -> k (a, c) (b, c);
  second :: k a b -> k (c, a) (c, b);
  split :: k a b -> k c d -> k (a, c) (b, d);
  fanout :: k a b -> k a c -> k a (b, c);
  second f = compose (arr swap) $ compose (first f) $ arr swap;
  split f g = compose (second g) $ first f;
  fanout f g = compose (split f g) $ arr $ \x -> (x, x);
  minimal arr, first;
};

class Arrow k => ArrowZero k where {
  zero_arrow :: k a b;
};

class ArrowZero k => ArrowPlus k where {
  plus :: k a b -> k a b -> k a b;
};
```

```tql
(.) :: Category k => k b c -> k a b -> k a c;
f . g = compose f g;

(|) :: Category k => k a b -> k b c -> k a c;
p | q = compose q p;
```

```
compose identity f  =  f  =  compose f identity
compose f (compose g h)  =  compose (compose f g) h

arr identity  =  identity
arr (g . f)  =  arr f | arr g
first (arr f)  =  arr (\(a, c) -> (f a, c))
first (f | g)  =  first f | first g
first f | arr fst  =  arr fst | f

plus zero_arrow f  =  f  =  plus f zero_arrow
plus (plus f g) h  =  plus f (plus g h)
```

Instances:

```
Category (->)                                  Arrow (->)
Monad m => Category (Kleisli m)                Monad m => Arrow (Kleisli m)
(Monad m, Alternative m) => ArrowZero (Kleisli m)
(Monad m, Alternative m) => ArrowPlus (Kleisli m)
```

So `Filter` has all four. At `Kleisli m`, composition is Kleisli
composition:

```
run_kleisli (p | q)  =  kleisli (run_kleisli p) (run_kleisli q)
```

`first` and `second` take their pair lazily.

## ToJson

```tql
class ToJson a where {
  to_json :: a -> Json;
  deriving %derive_to_json;
};
```

Instances:

| Instance | JSON |
|---|---|
| `ToJson Int` | a number |
| `ToJson String` | a string |
| `ToJson Bool` | `true` or `false` |
| `ToJson Ordering`, derived | its constructor's name, a string |
| `(ToJson a1, ..., ToJson an) => ToJson (a1, ..., an)` | an array of the components; `()` is `[]` |
| `ToJson a => ToJson [a]` | an array |
| `ToJson a => ToJson (Maybe a)` | `null` for `Nothing`, the value for `Just x` |
| `All ToJson ρ => ToJson (Record ρ)` | an object with one member per field ([Classes over rows](04-types.md#classes-over-rows)) |
| `ToJson Kind` | its name, a string |
| `ToJson Node` | `{"kind", "text", "start_byte", "end_byte", "start_point", "end_point"}`, each point `{"row", "column"}` |
| `ToJson Json` | itself |

`Regex` and function types have no instance. A derived instance encodes
by the datatype's shape ([Deriving](05-declarations.md#deriving)), and a
program's output is written by `to_json`
([Encoding](08-programs.md#encoding)).

## Filters

```tql
newtype Kleisli m a b = Kleisli (a -> m b);
type Filter = Kleisli List;

run_kleisli :: Kleisli m a b -> a -> m b;
run_kleisli (Kleisli f) = f;
```

A filter from `a` to `b` takes an `a` to a list of `b`s. `Filter` is a
synonym, so a filter is a `Kleisli List` arrow and has its instances. The
pipeline operator `|` composes filters, and `do` sequences them
([Pipeline](02-expressions.md#pipeline)).

```tql
run :: Filter a b -> a -> [b];
run = run_kleisli;

keep :: (a -> Bool) -> Filter a a;
keep f = Kleisli $ \x -> if f x then [x] else [];

collect :: Filter a b -> Filter a [b];
collect p = Kleisli $ \x -> [run p x];

has :: Filter a b -> a -> Bool;
has p x = not $ null $ run p x;

or_else :: Filter a b -> Filter a b -> Filter a b;
or_else p q = Kleisli $ \x -> case run p x of {
  [] -> run q x;
  ys -> ys;
};
```

`or_else` falls back only when its first filter yields nothing, where `<|>`
yields both.
