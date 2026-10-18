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

```tql
seq :: a -> b -> b;
seq a b = case a of { !_ -> b; };
```

`seq a b` evaluates `a` to its outermost constructor or lambda, then gives
`b`. `seq (\x -> loop) 1` is `1`; `seq loop 1` is `⊥`.

## Recursion and memory

A program's recursion depth is bounded only by memory. A run has a fixed
memory budget per file, and the memory a run holds is the memory its live
values need.

## Runtime errors

A well-typed program yields its value, diverges, or raises one of these
errors:

| Error | Cause |
|---|---|
| `cyclic-value` | forcing a value whose own evaluation is under way: `loop = loop; main = loop;` |
| `memory-limit` | the run's memory passed the per-file budget |
| `int-out-of-range` | [writing](08-programs.md#encoding) a number whose magnitude exceeds 2^53 - 1 |

Each means `⊥`. A program cannot raise an error of its own: TQL has no
`error` and no exceptions. A pattern that may fail where failure must be
handled is an error, `non-exhaustive`
([Coverage](03-patterns.md#coverage)), and a
partial operation in the library returns `Maybe`.
