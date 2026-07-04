# TQL

TQL is a query DSL over ASTs. A query selects nodes by traversing
the tree, binds them to variables, filters them, and projects each surviving
binding into a result value.

```tql
@root > function_definition.declarator as @func_decl
| @func_decl.parameters > parameter_declaration as @param_decl
| @func_decl.declarator as @func_name
| { name: @func_name, parameter: @param_decl }
```
*For every function in the tree, pair its name with each of its parameters.*

## Denotational model

A query evaluates against an `Env` — a current value `.` plus a map of named
variable bindings — and produces a list of result values.

```haskell
type Env = (TQLValue, Map Variable TQLValue)   -- (current '.', named @vars)

data TQLValue
  = TNothing
  | TString String
  | TNode   Node
  | TList   [TQLValue]
  | TRecord (Map String TQLValue)
  | ... -- omitted for brevity

type Eval = Env -> [TQLValue]
```

A pipeline is a sequence of steps chained with `|`. There are three step kinds:

| Step | Syntax | Semantics |
|---|---|---|
| Bind (fan-out) | `expr as @v` | extends `Map` with `@v`, fans over matches |
| Guard (filter) | `select(pred)` | keeps env only if `pred` holds |
| Transform | `expr` (not last) | replaces `.` with result of `expr` |

The whole pipeline is a list-monad fold:

```haskell
env0 >>= step_1 >>= ... >>= step_n >>= return . project
```

### Example

The query above has three bind steps and a final projection. Each bind step
`e as @v` is `\env -> [ insert "@v" x env | x <- eval e env ]`:

```haskell
b_func_decl, b_param_decl, b_func_name :: Env -> [Env]
b_func_decl  env = [ insert "func_decl"  x env
                   | x <- eval $ Field "declarator"
                                  (Child (Var "root") "function_definition") env ]
b_param_decl env = [ insert "param_decl" x env
                   | x <- eval $ Child (Field "parameters" (Var "func_decl"))
                                      "parameter_declaration" env ]
b_func_name  env = [ insert "func_name"  x env
                   | x <- eval $ Field "declarator" (Var "func_decl") env ]

proj :: Env -> TQLValue
proj env = TRecord (Map.fromList
  [ ("name",      env Map.! "func_name")
  , ("parameter", env Map.! "param_decl") ])
```

Each binding fans the env out over its matching nodes. On a file with two
functions where the first has two parameters and the second has one, the stream
after `b_param_decl` carries three envs, and `proj` emits three records.

### Quantifiers

`any(gen; cond)` and `all(gen; cond)` iterate over the results of `gen`,
binding each element to `.` for evaluation of `cond`:

```tql
@root > class_declaration as @c
| select(any(@c.body > method_definition; .name ~ /^test/))
| @c
```
