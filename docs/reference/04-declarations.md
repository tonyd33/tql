# Declarations and bindings

Every type, class and synonym of a module is in scope in every
declaration of the module, so declarations may refer to each other in
any order.

## Grammar

```
topdecl ::= "data" simpletype ("=" constrs)? deriving* ";"
          | "newtype" simpletype "=" con atype deriving* ";"
          | "type" simpletype "=" type ";"
          | "class" (context "=>")? upper tyvar "where" "{" (cdecl ";")* "}" ";"
          | "instance" (context "=>")? qcls inst "where" "{" (idecl ";")* "}" ";"
          | "pattern" con var* "<-" pat ";"
          | "pattern" con "::" sigtype ";"
          | fixity
          | decl

decl    ::= vars "::" sigtype ";"
          | funlhs "=" exp ";"
          | pat "=" exp ";"

simpletype ::= upper tvbind*
tvbind     ::= tyvar | "(" tyvar "::" kind ")"
constrs    ::= con atype* ("|" con atype*)*
deriving   ::= "deriving" "newtype"? "(" (qcls ("," qcls)*)? ")"
funlhs     ::= var apat* | "(" op ")" apat* | apat op apat
```

## Datatypes

```tql
data Shape = Circle Int | Rect Int Int deriving (Eq, Ord, ToJSON);
```

declares a type `Shape` and constructors

```
Circle :: Int -> Shape
Rect   :: Int -> Int -> Shape
```

A datatype is nominal: two declarations with the same constructors are
different types. Its parameters' kinds are inferred
([Kinds](05-types.md#kinds)) or written: `data Wrap (f :: Type -> Type) a = Wrap (f a);`.

A constructor field may have any type of kind `Type`, records included.
A field may mention only the declaration's own parameters.

## Newtypes

```tql
newtype Name = Name String;
```

declares a type with one constructor of one field. `Name` and `String` are
different types, and each has its own instances. A newtype has the
representation of its field: the constructor costs nothing, and matching
it forces nothing (M-New).

`coerce :: Coercible a b => a -> b` converts between a newtype and its
field, under any type constructor whose parameter allows it: `coerce` takes
`[Name]` to `[String]` without a traversal. Whether a parameter allows it
is its role: a parameter that only stands for stored values allows it,
and one whose identity matters to an instance, such as an ordered key,
does not.

## Type synonyms

```tql
type Named r = {name: String | r};
```

A synonym is transparent: `Named r` and `{name: String | r}` are the same
type. A use must supply every parameter. A synonym may expand to a type
constructor short of arguments: `type Filter = Kleisli List;`. A synonym
that refers to itself, directly or through others, is an error.

## Classes

```tql
class Eq a where {
  (==) :: a -> a -> Bool;
  (!=) :: a -> a -> Bool;
  x == y = not (x != y);
  x != y = not (x == y);
  minimal (==) | (!=);
};
```

declares a class `Eq` with methods `==` and `!=`, each of type
`∀a. Eq a => a -> a -> Bool`. A class has one parameter, and a method
type that does not mention it is an error. A context before `=>` names
the superclasses: `class Eq a => Ord a`. A cycle of superclasses is an
error.

A method with a definition in the class has a default, used by every
instance that does not define it. Each class states which methods an
instance must define; for `Eq` it is `==` or `!=`. `minimal` joins methods
with `,`, all of them, and `|`, either side, `,` binding tighter; without
it, an instance must define every method without a default. A `minimal`
that an instance could satisfy while leaving a method without a default
undefined is an error, as is an instance that defines too few.

A class translates to a dictionary type and selectors:

```
class S1 a, ..., Sk a => C a where { m1 :: τ1; ...; mn :: τn }

data Dict_C a = Dict_C (Dict_S1 a) ... (Dict_Sk a) τ1 ... τn
mi       :: ∀a. Dict_C a -> τi
super_Sj :: ∀a. Dict_C a -> Dict_Sj a
```

A method's type may quantify further variables; the dictionary's field is
then polymorphic.

## Instances

```tql
instance Eq a => Eq (Maybe a) where {
  Nothing == Nothing = True;
  Just x == Just y = x == y;
  _ == _ = False;
};
```

The head is a type constructor applied to distinct type variables:
`Maybe a`, `Either e`, `(->) a`, `(a, b)`. The context constrains only
those variables. The head's kind must be the class parameter's kind.

Instances are global: a program sees every instance of every module it
links. For each class and head there is at most one instance in a
program, and it is declared in the module of its class or the module of
its type. An instance anywhere else is an orphan, and an error.

Each method is checked against the class's method type at the head, with
the instance context and the head's superclass instances as givens.

Each superclass `S` of `C` is a wanted `S (T ā)`, solved with the context
as givens. Its evidence is the dictionary's superclass field. An insoluble
one is an error, `invalid-instance`.

An instance translates to a dictionary, a function of the context's
dictionaries:

```
instance (C1 a1, ..., Cj aj) => C (T ā) where { ... }

inst_C_T :: ∀ā. Dict_C1 a1 -> ... -> Dict_Cj aj -> Dict_C (T ā)
```

## Deriving

`deriving (C1, ..., Cn)` on a `data` or `newtype` declaration generates an
instance of each class. Its context is the least under which every
field's wanted `C τ` is solved: starting from no context, each residual
on a type variable is added until none is. `data P a = P` derives
`Eq (P a)` with no context. A residual on any type but a variable is an
error, `invalid-deriving`.

| Class | Derived instance |
|---|---|
| `Eq` | equal when the constructors are equal and the fields are equal, left to right |
| `Ord` | ordered by constructor, in declaration order, then by fields, left to right |
| `ToJSON` | the encoding in [Output](08-programs.md#output) |
| `Functor`, `Foldable`, `Traversable` | over the last parameter, field by field |

A derived comparison forces fields only up to the first difference.

A class outside this table is derived through a generic representation
of the datatype: its constructors and fields as a value the class's
library code can traverse.

`deriving newtype (C)` on a newtype reuses the field's instance through
`coerce`.

## Type signatures

```tql
pairs :: Ord a => [a] -> [(a, a)];
```

A signature gives a binding its type. It may appear at top level and in
a `let`, beside the binding it types. The type variables of a signature
are quantified over the signature alone.

A binding with a signature is checked against it ([T-Sig](06-static-semantics.md#bindings)).
Every use of it, recursive ones included, is at the signature's type, so
a signed binding may be polymorphically recursive.

## Function bindings

```
f p11 ... p1k = e1;
...
f pn1 ... pnk = en;
```

Adjacent clauses of one name form one definition. Every clause has the
same number of patterns.

```
f = \x1 ... xk -> case (x1, ..., xk) of {
  (p11, ..., p1k) -> e1;
  ...
  (pn1, ..., pnk) -> en;
}
```

The clauses must be exhaustive.

## Pattern synonyms

```tql
pattern Call f <- :call_expression { #function = f };
```

declares a pattern `Call f` that matches what its right-hand side matches
and binds `f`. Each parameter occurs once in the body, and the body binds
nothing else. A use supplies every parameter. A synonym may not refer to
itself, directly or through others, and may not be used as an expression.

The synonym translates to a matcher. Its free names are resolved where it
is declared:

```
pattern P x1 ... xn <- p

matcher_P :: ∀r. τ -> (τ1 -> ... -> τn -> r) -> r -> r
matcher_P v k f = case v of { p -> k x1 ... xn; _ -> f }
```

A signature `pattern P :: τ1 -> ... -> τn -> τ;` gives `P` the type a
constructor would have. It may be narrower than the type inferred from the
body.

## Fixity

Each operator has a fixity: an associativity (`infixl`, `infixr` or
`infix`) and a level. A fixity belongs to the operator's binding: it is
exported and imported with the name. An operator with no fixity
declaration is `infixl 9`. The standard library's fixities are in
[Operators](02-expressions.md#operators).

## Binding groups

The bindings of one module, or of one `let`, are split into strongly
connected components of their reference graph and typed in dependency
order. A reference to a binding with a signature is not an edge. One
component is typed together ([T-Group](06-static-semantics.md#bindings)).

## Generalisation

A binding's type is generalised over the type variables that do not occur
in its environment, with two restrictions.

At top level, a binding with no parameters and no signature is not
generalised over its constrained type variables, and its uses fix them:

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
