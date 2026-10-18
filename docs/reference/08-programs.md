# Programs

## The entry point

A program is an entry module and the modules it imports. The entry module
defines `main`:

```tql
main :: Filter Node String;
main = descendants_of_kind :function_declaration | #name | arr text;
```

`main` is an ordinary definition. The program's meaning is that of the
generated binding

```
entry = run_main main

run_main :: ToJSON t => Filter Node t -> Node -> [Json]
run_main m root = map to_json (run m root)
```

which the checker checks like any other. So `main` must be a filter from
`Node` whose outputs have `ToJSON`, and nothing else is required of it. A
type variable left in `main`'s type is legal unless a constraint on it is
ambiguous: `data P a = P deriving (ToJSON); main = pure P;` is accepted,
since `ToJSON (P a)` holds for every `a`.

An entry module with no `main` is an error, `missing-main`.

## Runs

A program runs once per target file, on the root of that file's syntax
tree. Runs share nothing, and a run reads no file but its own.

A target file with syntax errors is a tree like any other, with `ERROR`
and missing nodes in it ([Syntax errors](09-tree.md#syntax-errors)). The
run goes ahead, and the program decides what the errors mean.

## Output

A run's output is the list `entry root`, in order. Each element is forced
in full and written as JSON before the next is forced.

If forcing an element, or the spine of the list, fails with an error
([Runtime errors](10-evaluation.md#runtime-errors)), the elements before it
are the run's output, the failing element is not, and the error is
reported. Nothing after it is forced. A file whose run fails does not stop
the runs of other files.

### Encoding

`to_json` gives the JSON value of an output. The library's instances:

| Type | JSON |
|---|---|
| `Int` | a number |
| `String` | a string |
| `Bool` | `true` or `false` |
| `()` | `[]` |
| `[a]` | an array |
| `(a1, ..., an)` | an array of n elements |
| `Maybe a` | `null` for `Nothing`, the value for `Just x` |
| a record | an object with one member per field |
| `Kind` | its name, a string |
| `Node` | `{"kind", "text", "start_byte", "end_byte", "start_point", "end_point"}`, each point `{"row", "column"}` |
| `Json` | itself |

`Regex` and function types have no instance.

An `Int` whose magnitude exceeds 2^53 - 1 cannot be encoded: encoding it
is a runtime error, so every number a program writes is exact in every
JSON reader.

A derived instance encodes a datatype by its shape:

| Datatype | JSON of `C x1 ... xn` |
|---|---|
| one constructor, one field | the field |
| one constructor, n ≠ 1 fields | an array of the fields |
| several constructors, all without fields | the constructor's name |
| several constructors otherwise | `{"tag": "C"}` with no fields, `{"tag": "C", "contents": x1}` with one, `{"tag": "C", "contents": [x1, ..., xn]}` with more |
| a newtype | its field |

So `data Shape = Circle Int | Rect Int Int deriving (ToJSON);` writes
`Rect 2 3` as `{"tag":"Rect","contents":[2,3]}`, and `Ordering` writes
`LT` as `"LT"`.
