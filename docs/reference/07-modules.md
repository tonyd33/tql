# Modules

## Grammar

```
module  ::= header? import* topdecl*
header  ::= "module" modid exports? grammars? ";"
exports ::= "(" (export ("," export)*)? ")"
export  ::= qvar | qtycon ("(" ".." ")")? | qcls ("(" ".." ")")? | "module" modid
grammars ::= "for" lower ("," lower)*

import  ::= "import" modid items? ("as" modid)? ";"
items   ::= "(" (item ("," item)*)? ")" | "hiding" "(" (item ("," item)*)? ")"
item    ::= var | tycon ("(" ".." ")")? | cls ("(" ".." ")")?
```

A module is one file. Its name is dotted, `Data.List`, and is found as the
file `Data/List.tql`. An import of a module that is not found is an
error, `unresolved-module`.

A module with no header is the program's entry module, `Main`. Every
imported module has a header naming it, or it is an error,
`module-name-mismatch`.

## Exports

With no export list, a module exports every top-level declaration it
makes. An export list names what it exports:

| Item | Exports |
|---|---|
| `x` | the value `x` |
| `T` | the type `T`, without its constructors |
| `T(..)` | the type `T` and its constructors |
| `C` | the class `C`, without its methods |
| `C(..)` | the class `C` and its methods |
| `module M` | everything this module imports from `M` unqualified |

An export list may name an imported entity. Two exports of one name that
denote different entities are an error, `conflicting-export`.

## Imports

| Import | Brings into scope |
|---|---|
| `import M;` | everything `M` exports, unqualified |
| `import M (x, T(..));` | the listed entities, unqualified |
| `import M hiding (x);` | everything `M` exports but `x`, unqualified |
| `import M as Q;` | everything `M` exports, as `Q.x` only |

`import M as Q` is the only qualified import; there is no `qualified`
keyword. `import M` does not bring `M.x` into scope. Several imports may share one
qualifier. Imports are not transitive: importing `A`, which imports `B`,
does not bring `B`'s names into scope.

Every module but those of the standard library imports `Prelude`
implicitly, unless it imports `Prelude` itself, as in
`import Prelude hiding (map);`.

Instances are not imported by name. A program sees every instance of
every module it links ([Instance](05-declarations.md#instance)).

## Name resolution

An unqualified name resolves in the first of these layers that binds it:

1. the nearest enclosing local binding;
2. the module's own top-level declarations;
3. the entities its unqualified imports list by name, `import M (x)`;
4. the entities its other unqualified imports bring in, `import M` and
   `import M hiding (y)`;
5. the implicit `Prelude`.

A layer hides every layer below it without error. A name bound by no
layer is an error, `unresolved-name`. A name that one layer binds to two
different entities is an error, `ambiguous-name`, at each use; a name
bound twice to one entity is not ambiguous.

A qualified name `Q.x` resolves only through the imports under `Q`, and
never to the module's own declaration; otherwise it is an error,
`unresolved-name`.

There are two namespaces. Variables and constructors share the value
namespace; types, synonyms and classes share the type namespace.

## Import cycles

The import graph's strongly connected components are the units of
checking. A component is one module when no cycle passes through it, and
every module of the cycle otherwise. Components are checked in dependency
order, each against the interfaces of the components it imports, and each
produces one interface.

Inside a component:

- The export lists are solved together, as the least sets that satisfy
  every module's list.
- The type-level declarations of every module are kinded as one set of
  dependency groups.
- Values are typed by binding group across the whole component.

So modules may import each other, and no declaration needs to be written
twice.

## Grammars

A target grammar is named by a `for` clause. A module with a `for` clause
may use the kind literals and fields of its grammars. A module without one
is generic: it may not name kinds or fields, and it imports only generic
modules. A generic module that names a kind, a field or a module with a
`for` clause, or a program whose modules name different grammars, is an
error, `grammar-mismatch`.

## The library

The standard library is a set of modules bundled with the engine, found
after the program's own search path. A program module that takes a
library module's name is an error, `ambiguous-module`. Library modules
name primitives by `%` names: `Prim` binds the primitive types and
operations, and a class its deriver. A primitive named outside the
library is an error, `unresolved-name`. The `Prelude`
re-exports the common parts of the library. The modules and their contents
are in [Predefined types and classes](11-library.md).
