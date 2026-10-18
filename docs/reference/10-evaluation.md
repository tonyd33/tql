# Evaluation

## Non-strict semantics

TQL is non-strict. An expression is evaluated only when its value is
needed, and then only as far as it is needed. A constructor's fields are
not evaluated when it is built, so `Cons 1 loop` is a list whose tail
diverges, and `head (Cons 1 loop)` is `Just 1`.

Evaluation is call-by-need: a value bound by `let`, passed as an argument
or stored in a constructor is evaluated at most once and shared by every
use.

The meaning of an expression is an element of a domain with a least
element `⊥`, the meaning of every expression that diverges or raises an
error. Functions are lifted: `\x -> ⊥` is a value, distinct from `⊥`,
since `seq` tells them apart. A top-level binding means the least fixed
point of its definition.

```
seq :: a -> b -> b
seq a b = case a of { !_ -> b }
```

`seq a b` evaluates `a` to its outermost constructor or lambda, then gives
`b`. `seq (\x -> loop) 1` is `1`; `seq loop 1` is `⊥`.

## Recursion and memory

A program's recursion depth is bounded only by memory. A run has a fixed
memory budget per file, and the memory a run holds is the memory its live
values need.

## Integers

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

## Strings

A `String` is well-formed UTF-8 text. Text read from outside the program,
a node's source or a file name, is decoded with each maximal ill-formed
subsequence replaced by U+FFFD. `length` counts code points. Strings compare by code point.

## Regular expressions

`s ~ r` holds when `r` matches somewhere in `s`, and `s !~ r` when it
does not. Matching takes time linear in the length of `s`, for every
pattern, and never fails.

The dialect:

- matches over code points;
- `\d`, `\w` and `\s` are ASCII;
- `(?i)` folds case;
- has no backreferences, lookaround, recursion, possessive quantifiers,
  atomic groups or backtracking verbs.

A pattern outside the dialect is a compile error, `invalid-regex`.

## Runtime errors

A well-typed program yields its value, diverges, or raises one of these
errors:

| Error | Cause |
|---|---|
| `cyclic-value` | forcing a value whose own evaluation is under way: `loop = loop; main = loop;` |
| `memory-limit` | the run's memory passed the per-file budget |
| an `Int` out of range | encoding an `Int` whose magnitude exceeds 2^53 - 1 as JSON |

Each means `⊥`. A program cannot raise an error of its own: TQL has no
`error` and no exceptions. A pattern that may fail where failure must be
handled is a compile error ([Coverage](03-patterns.md#coverage)), and a
partial operation in the library returns `Maybe`.
