# The standard library

This chapter gives the library's classes, the laws every instance must
satisfy, and the instances the library provides. The laws are equations
between meanings, `⊥` included. The library and the optimiser rely on
them ([Typed Core and the optimiser](13-core.md)); an instance that breaks
one gets results the laws do not predict.

## Modules

| Module | Contents |
|---|---|
| `Prim` | primitive types and operations |
| `Prelude` | the common names below, imported implicitly |
| `Data.Bool` | `not`, `&&`, `\|\|`, `and`, `or` |
| `Data.Int` | `+`, `-`, `*`, `div`, `mod`, `quot`, `rem`, `subtract`, `toint` |
| `Data.Ord` | `Ord` and its functions |
| `Data.List` | list functions, `Sized` |
| `Data.Maybe` | `Maybe` functions |
| `Data.Tuple` | `fst`, `snd` |
| `Data.Function` | `$`, `identity`, `.` |
| `Data.Functor` | `Functor` |
| `Data.Foldable` | `Foldable` and its functions |
| `Data.Traversable` | `Traversable`, `sequence` |
| `Data.Monoid` | `Semigroup`, `Monoid` |
| `Data.Filter` | `Filter`, `run`, `collect`, `keep`, `has`, `or_else` |
| `Data.Node` | the tree operations and axes |
| `Control.Category` | `Category`, `\|` |
| `Control.Arrow` | `Arrow`, `ArrowZero`, `ArrowPlus`, `Kleisli` |
| `Control.Applicative` | `Applicative`, `Alternative`, `<\|>`, `guard` |
| `Control.Monad` | `Monad`, `>>`, `join`, `kleisli`, `mfilter` |

## Eq and Ord

```tql
class Eq a where {
  (==) :: a -> a -> Bool;
  (!=) :: a -> a -> Bool;
};

class Eq a => Ord a where {
  compare :: a -> a -> Ordering;
  (<) :: a -> a -> Bool;
  (<=) :: a -> a -> Bool;
  (>) :: a -> a -> Bool;
  (>=) :: a -> a -> Bool;
  max :: a -> a -> a;
  min :: a -> a -> a;
};
```

An `Eq` instance defines `==` or `!=`, and an `Ord` instance `compare` or
`<=`; the other methods have defaults.

Laws:

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

Instances: `Int` and `String` (by code point) have both. `Node` and
`Kind` have `Eq` only. `List` (lexicographic, a prefix first), `Bool`
(`False < True`), `Ordering`, `Maybe` (`Nothing` first), every tuple and
every record have both. No function type has either.

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

Instances: lists (concatenation), `()`, and `Ordering` (the first
non-`EQ`).

## Functor, Applicative, Monad and Alternative

```tql
class Functor f where {
  map :: (a -> b) -> f a -> f b;
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

The last law is what makes a failing `do` bind ([Do](02-expressions.md#do))
mean what it says.

```
x <|> y   =  alt x y
x >> y    =  bind x (\_ -> y)
return    =  pure
guard b   =  if b then pure () else empty
kleisli p q x  =  bind (p x) q
```

Instances: `List`, `Maybe`, `Kleisli m a` when `m` has the instance, and
so `Filter a`. At lists, `ap` is the Cartesian product, function-major,
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
};

class (Functor t, Foldable t) => Traversable t where {
  traverse :: Applicative f => (a -> f b) -> t a -> f (t b);
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

Instances: `List` and `Maybe`. The folds over them are lazy in the
accumulator, so `any`, `all` and `null` stop at the first element that
decides them.

## Sized

```tql
class Sized a where {
  length :: a -> Int;
};
```

Instances: lists, and `String`, which counts code points.

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
};

class Arrow k => ArrowZero k where {
  zero_arrow :: k a b;
};

class ArrowZero k => ArrowPlus k where {
  plus :: k a b -> k a b -> k a b;
};
```

```
f . g      =  compose f g
p | q      =  compose q p

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

Instances: `(->)`, and `Kleisli m` for a monad `m`, so `Filter`. At
`Kleisli m`, composition is Kleisli composition:

```
run_kleisli (p | q)  =  kleisli (run_kleisli p) (run_kleisli q)
```

`ArrowZero` and `ArrowPlus` hold at `Kleisli m` when `m` is also
`Alternative`. `first` and `second` take their pair lazily.

## ToJSON

```tql
class ToJSON a where {
  to_json :: a -> Json;
};
```

The instances and the derived encoding are in [Output](08-programs.md#output).

## Filters

```
run          =  run_kleisli
keep f       =  Kleisli (\x -> if f x then [x] else [])
collect p    =  Kleisli (\x -> [run p x])
has p x      =  not (null (run p x))
or_else p q  =  Kleisli (\x -> case run p x of { [] -> run q x; ys -> ys; })
```

`or_else` falls back only when its first filter yields nothing, where `<|>`
yields both.
