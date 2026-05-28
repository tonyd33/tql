# TQL

TQL is a query DSL over ASTs. A query selects nodes by traversing
the tree, binds them to variables, filters them, and projects each surviving
binding into a result value.

```tql
with @root > function_definition.declarator as @func_decl,
     @func_decl.parameters > parameter_declaration as @param_decl,
     @func_decl.declarator as @func_name
select { name: @func_name, parameter: @param_decl }
```
*For every function in the tree, pair its name with each of its parameters.*

## Denotational model

A query evaluates against an `Env` (a map of variable bindings) and produces a
list of result values.

```haskell
type Env = Map Variable TQLValue

data TQLValue
  = TNothing
  | TString String
  | TNode   Node
  | TList   [TQLValue]
  | TRecord (Map String TQLValue)
  | ... -- omitted for brevity

type Eval = Env -> [TQLValue]

type Bind   = Env -> [Env]      -- with
type Filter = Env -> Bool       -- where
type Proj   = Env -> TQLValue   -- select

compileQuery :: [Bind] -> Filter -> Proj -> Eval
compileQuery binds keep proj = \env0 -> do
  env <- foldM (&) env0 binds   -- thread env through each with
  guard $ keep env              -- drop envs failing where
  return $ proj env             -- project surviving env
```

The whole pipeline is a list-monad fold:

```haskell
env0 >>= with_1 >>= ... >>= with_n >>= filter where_ >>= return . select
```

### Example

The query above desugars to three `Bind`s, a trivially-true `Filter`, and a
record-building `Proj`. Each `Bind` of the form `e as @v` is just `\env -> [
Map.insert "v" x env | x <- eval e env ]`:

```haskell
b_func_decl, b_param_decl, b_func_name :: Bind
b_func_decl  env = [ Map.insert "func_decl"  x env
                   | x <- eval $ Field "declarator"
                                  (Child (Var "root") "function_definition") env ]
b_param_decl env = [ Map.insert "param_decl" x env
                   | x <- eval $ Child (Field "parameters" (Var "func_decl"))
                                      "parameter_declaration" env ]
b_func_name  env = [ Map.insert "func_name"  x env
                   | x <- eval $ Field "declarator" (Var "func_decl") env ]

keep :: Filter
keep _ = True

proj :: Proj
proj env = TRecord (Map.fromList
  [ ("name",      env Map.! "func_name")
  , ("parameter", env Map.! "param_decl") ])

runExample :: Eval
runExample = compileQuery [b_func_decl, b_param_decl, b_func_name] keep proj
```

Each binding fans the env out over its matching nodes. On a file with two
functions where the first has two parameters and the second has one, the stream
after `b_param_decl` carries three envs, and `proj` emits three records.

### Projection desugaring

In the canonical form, a `Proj` is just a single variable lookup (e.g. `proj
env = env Map.! "v"`). Anything more complex in `select`, including record and
list literals, is itself a TQL expression and gets hoisted into a fresh `with`
binding (preserving referential transparency). Writing `<expr>` for any
TQL expression:

```tql
select <expr>
```

is sugar for:

```tql
with <expr> as @__e
select @__e
```

The record literal in the original example follows the same rule: it is one
expression, hoisted into a single binding, and the `select` reduces to a
variable lookup. So all evaluation (selectors, navigation, record
construction, function calls) happens inside `Bind`s; the `Proj` is purely a
read from the env.
