# Programs

## The entry point

A program is an entry module and the modules it imports. The entry module
defines `main`:

```tql
main :: Filter Node String;
main = descendants_of_kind :function_declaration | #name | arr text;
```

`main` is an ordinary definition. The program means the generated binding

```
entry = run_main main

run_main :: ToJson t => Filter Node t -> Node -> [Json]
run_main m root = map to_json (run m root)
```

which is checked like any other. So `main` must be a filter from `Node`
whose outputs have `ToJson`, and nothing else is required of it. A type
variable left in `main`'s type is legal unless a constraint on it is
ambiguous: `data P a = P deriving (ToJson); main = pure P;` is accepted,
since `ToJson (P a)` holds for every `a`.

An entry module with no `main` is an error, `missing-main`.

## Runs

A target file is a file a program runs on. A program runs once per
target file, on the root of that file's syntax
tree. Runs share nothing, and a run reads no file but its own. A run has
no effect but its output: there is no `IO`. A run that
fails does not stop the others.

A target file with syntax errors is a tree like any other, with `ERROR`
and missing nodes in it ([Syntax errors](09-tree.md#syntax-errors)). The
run goes ahead, and the program decides what the errors mean.

## Output

A run's output is the list `entry root`, in order. Each element is forced
in full and written as JSON before the next is forced.

If forcing an element or the spine of the list, or writing an element,
fails with an error
([Runtime errors](10-evaluation.md#runtime-errors)), the elements before it
are the run's output, the failing element is not, and the error is
reported. Nothing after it is forced.

### Encoding

Each element is written as the JSON value `to_json` gives it
([ToJson](11-library.md#tojson)). Writing a number whose magnitude
exceeds 2^53 - 1 is a runtime error, `int-out-of-range`.
