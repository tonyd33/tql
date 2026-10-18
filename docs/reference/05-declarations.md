# Declarations and bindings

Every type, class and synonym of a module is in scope in every
declaration of the module, so declarations may refer to each other in
any order.

## Grammar

```
topdecl ::= "data" simpletype ("=" constrs)? deriving* ";"
          | "newtype" simpletype "=" con atype deriving* ";"
          | "type" simpletype "=" type ";"
          | "class" (context "=>")? cls tyvar "where" "{" (cdecl ";")* "}" ";"
          | "class" cls "=" primitive ";"
          | "instance" (context "=>")? qcls inst "where" "{" (idecl ";")* "}" ";"
          | "pattern" con var* "<-" pat ";"
          | "pattern" con "::" sigtype ";"
          | fixity ";"
          | rule ";"
          | decl ";"

decl    ::= vars "::" sigtype
          | funlhs "=" exp
          | pat "=" exp

cdecl   ::= vars "::" sigtype | funlhs "=" exp | "minimal" formula | "deriving" primitive
idecl   ::= funlhs "=" exp
formula ::= formula "|" formula | formula "," formula | "(" formula ")" | var

inst    ::= qtycon tyvar*
          | "(" qtycon tyvar* ")"
          | "(" tyvar ("," tyvar)+ ")"   |   "(" ")"
          | "[" tyvar "]"
          | "(" "->" ")" tyvar*

fixity  ::= ("infixl" | "infixr" | "infix") integer op ("," op)*

simpletype ::= tycon tvbind*
tvbind     ::= tyvar | "(" tyvar "::" kind ")"
constrs    ::= con atype* ("|" con atype*)*
deriving   ::= "deriving" "newtype"? "(" (qcls ("," qcls)*)? ")"
funlhs     ::= var apat* | apat varop apat
vars       ::= var ("," var)*
```

## Datatype

```tql
data Shape = Circle Int | Rect Int Int deriving (Eq, Ord, ToJson);
```

declares a type `Shape` and constructors

```
Circle :: Int -> Shape
Rect   :: Int -> Int -> Shape
```

A datatype is nominal: two declarations with the same constructors are
different types. Its parameters' kinds are inferred
([Kinds](04-types.md#kinds)) or written:
`data Wrap (f :: Type -> Type) a = Wrap (f a);`.

A field may have any type of kind `Type`, records included, and may
mention only the declaration's own parameters; another type variable is
an error, `unresolved-name`.

## Newtype

```tql
newtype Name = Name String;
```

declares a nominal type with one constructor of one field: `Name` and
`String` are different types, each with its own instances. A newtype has
the representation of its field: the constructor costs nothing, and
matching it forces nothing (M-New).

`coerce :: Coercible a b => a -> b` converts between a newtype and its
field, under any type constructor whose parameter allows it: `coerce`
takes `[Name]` to `[String]` without a traversal. Whether a parameter
allows it is its role: a parameter that only stands for stored values
allows it, and one whose identity matters to an instance, such as an
ordered key, does not.

## Type synonym

```tql
type Named r = {name: String | r};
```

A synonym is transparent: `Named r` and `{name: String | r}` are the same
type. A use must supply every parameter, or it is an error,
`unsaturated-synonym`. A synonym may expand to a type constructor short
of arguments: `type Filter = Kleisli List;`. A synonym that refers to
itself, directly or through others, is an error, `cyclic-alias`.

## Class

```tql
class Eq a where {
  (==) :: a -> a -> Bool;
  (!=) :: a -> a -> Bool;
  x == y = not (x != y);
  x != y = not (x == y);
  minimal (==) | (!=);
  deriving %derive_eq;
};
```

declares a class `Eq` with methods `==` and `!=`, each of type
`∀a. Eq a => a -> a -> Bool`. A class has one parameter. A method type
must mention it and may mention other type variables, which the method's
type quantifies. A context before `=>` names the superclasses:
`class Eq a => Ord a`. A method type that does not mention the parameter,
or a cycle of superclasses, is an error, `invalid-class`.

A method defined in the class has a default, used by every instance that
does not define the method. `minimal` states which methods an instance
must define: `,` requires both sides and `|` either, with `,` binding
tighter. For `Eq` it is `==` or `!=`. Without `minimal`, an instance must
define every method without a default. An instance that defines too few
is an error, `invalid-instance`.

`deriving` names the class's deriver, a primitive
([Deriving](#deriving)). Only a library module names one
([The library](07-modules.md#the-library)).

A class states `minimal` and `deriving` at most once each, a `minimal` or
default names only methods of the class, and its deriver defines a method
the class has, at the type the class gives it, that satisfies `minimal`
alone; otherwise it is an error, `invalid-class`. So is a `minimal` that
an instance could satisfy while leaving a method without a default
undefined. A default defined twice is `duplicate-definition`.

`class All = %all;` binds a class to a primitive: the class takes the
primitive's parameters, and the solver supplies its instances. Only a
library module binds one.

A class is represented by a dictionary type
([Elaboration](12-core.md#elaboration)).

## Instance

```tql
instance Eq a => Eq (Maybe a) where {
  Nothing == Nothing = True;
  Just x == Just y = x == y;
  _ == _ = False;
};
```

The head is a type constructor applied to distinct type variables:
`Maybe a`, `Either e`, `(->) a`, `(a, b)`. The context constrains only
those variables. A head or context of any other form is an error,
`invalid-instance`. The head's kind must be the class parameter's kind,
or it is an error, `kind-mismatch`.

Instances are global: a program sees every instance of every module it
links. For each class and head there is at most one instance in a
program; a second is an error, `duplicate-instance`. It is declared in
the module of its class or the module of its type. An instance anywhere
else is an orphan, an error, `orphan-instance`.

An instance defines only methods of its class: a definition of anything
else is `invalid-instance`, and a method defined twice is
`duplicate-definition`.

Each method is checked against the class's method type at the head, with
the instance context and the head's superclass instances as givens. Each
superclass `S` of `C` is a wanted `S (T ā)`, solved with the context as
givens. An insoluble one is an error, `invalid-instance`.

An instance is represented by a dictionary, a function of the context's
dictionaries ([Elaboration](12-core.md#elaboration)).

## Deriving

`deriving (C1, ..., Cn)` on a `data` or `newtype` declaration generates an
instance of each class. A class is derivable when its body names a
deriver. The deriver defines methods by the datatype's shape, the class's
defaults define the rest, and the instance is judged as a written one
([Class](#class)). Deriving a class that is not derivable, or naming a
class twice in one clause, is an error, `invalid-deriving`.

The library's derivers:

| Class | Deriver | Defines |
|---|---|---|
| `Eq` | `%derive_eq` | `==`: equal when the constructors are equal and the fields are equal, left to right |
| `Ord` | `%derive_ord` | `compare`: ordered by constructor, in declaration order, then by fields, left to right |
| `ToJson` | `%derive_to_json` | `to_json`: by the datatype's shape, below |
| `Functor` | `%derive_functor` | `map`, over the last parameter |
| `Foldable` | `%derive_foldable` | `foldr`, over the last parameter |
| `Traversable` | `%derive_traversable` | `traverse`, over the last parameter |

A derived comparison forces fields only up to the first difference.

An `Eq`, `Ord` or `ToJson` instance is for the datatype applied to its
parameters, and each field of type `τ` wants `C τ`. A `Functor`,
`Foldable` or `Traversable` instance is for the datatype applied to all
its parameters but the last, `a`, which has kind `Type`. Each field is
mapped, folded or traversed by its type, left to right:

| Field type | Treated as |
|---|---|
| one not mentioning `a` | itself, untouched |
| `a` | an element |
| a tuple or a record | its components, each by its type |
| `g τ`, `a` only in `τ` | through `g`'s instance of the class, which is wanted |
| `σ -> τ`, `a` only in `τ`, for `Functor` | `τ`, after the function |

`a` anywhere else, such as in `g`, in a function's argument, or in any
function for `Foldable` or `Traversable`, is an error, `invalid-deriving`.

The instance's context is the least under which its wanteds are solved:
starting from no context, each residual on a type variable is added until
none is left. A residual on any other type is an error,
`invalid-deriving`. `data P a = P` derives `Eq (P a)` with no context,
and `data T f a = T (f a)` derives `Functor f => Functor (T f)`.

A derived `ToJson` encodes a datatype by its shape:

| Datatype | JSON of `C x1 ... xn` |
|---|---|
| one constructor, one field | the field |
| one constructor, n ≠ 1 fields | an array of the fields |
| several constructors, all without fields | the constructor's name |
| several constructors otherwise | `{"tag": "C"}` with no fields, `{"tag": "C", "contents": x1}` with one, `{"tag": "C", "contents": [x1, ..., xn]}` with more |

A newtype has one constructor with one field, so it is written as its
field. `data Shape = Circle Int | Rect Int Int deriving (ToJson);` writes
`Rect 2 3` as `{"tag":"Rect","contents":[2,3]}`, and `Ordering` writes
`LT` as `"LT"`.

A class may also be derivable through a generic representation of the
datatype: its constructors and fields as a value the class's library code
can traverse.

`deriving newtype (C)` on a newtype reuses the field's instance through
`coerce`.

## Type signature

```tql
pairs :: Ord a => [a] -> [(a, a)];
```

A signature gives a binding its type. It may appear at top level and in
a `let`, beside the binding it types. The type variables of a signature
are quantified over the signature alone. A signature with no binding is
an error, `orphan-signature`, and a second signature for one name is an
error, `duplicate-signature`.

A signed binding is checked against its signature
([T-Sig](06-static-semantics.md#bindings)). Every use of it, recursive
ones included, is at the signature's type, so a signed binding may be
polymorphically recursive.

## Function binding

```
f p11 ... p1k = e1;
...
f pn1 ... pnk = en;
```

Adjacent clauses of one name form one definition, and clauses of one
name that are not adjacent are an error, `duplicate-definition`. Clauses
with different numbers of patterns are an error, `arity-mismatch`, and
clauses that are not exhaustive are an error, `non-exhaustive`. The
definition is

```
f = \x1 ... xk -> case (x1, ..., xk) of {
  (p11, ..., p1k) -> e1;
  ...
  (pn1, ..., pnk) -> en;
};
```

## Binding group

The bindings of one module, or of one `let`, are split into strongly
connected components of their reference graph and typed in dependency
order. A reference to a signed binding is not an edge. One component is
typed together ([T-Group](06-static-semantics.md#bindings)).

## Generalisation

A binding's type is generalised over the type variables that do not occur
in its environment, with two restrictions.

At top level, a binding group containing a binding with no parameters
and no signature is not generalised over its constrained type variables,
and its uses fix them:

```tql
one = pure 1;
main = one | identity;
```

Here `one` is used at `Filter Node`, so it is `Filter Node Int`, and it is
computed once. A binding whose type is not constrained still generalises:
`calls = descendants_of_kind :call_expression;` is unaffected.

A local binding that mentions a variable bound by an enclosing lambda,
case alternative or `do` bind is not generalised. A closed local binding
is generalised. A local signature generalises any binding.

A constrained type variable that nothing fixes is an error,
`ambiguous-constraint` ([Ambiguity](06-static-semantics.md#ambiguity)).

## Pattern synonym

```tql
pattern Call f <- :call_expression { #function = f };
```

declares a pattern `Call f` that matches what its right-hand side matches
and binds `f`. Each parameter occurs once in the body, and the body binds
nothing else; otherwise it is an error, `invalid-synonym`. A use must
supply every parameter, or it is an error, `unsaturated-synonym`. A
synonym used as an expression is an error, `unresolved-name`, and one
that refers to itself, directly or through others, is an error,
`cyclic-synonym`.

A synonym translates to a matcher, whose free names are resolved where
the synonym is declared:

```
pattern P x1 ... xn <- p

matcher_P :: ∀r. τ -> (τ1 -> ... -> τn -> r) -> r -> r
matcher_P v ok no = case v of { p -> ok x1 ... xn; _ -> no; }
```

A signature `pattern P :: τ1 -> ... -> τn -> τ;` gives `P` the type a
constructor would have. It may be narrower than the type inferred from
the body.

## Fixity

```tql
infixl 6 +, -;
```

Each operator has a fixity: an associativity (`infixl`, `infixr` or
`infix`) and a level, any integer; a higher level binds tighter. A
fixity belongs to the operator's binding, and is exported and imported
with the name. An operator with no fixity
declaration is `infixl 9`. The standard library's fixities are in
[Operator application](02-expressions.md#operator-application).
