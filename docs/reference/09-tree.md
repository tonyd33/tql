# The tree

A run's input is the syntax tree tree-sitter builds for one target file.
A `Node` is one node of that tree.

## Nodes

`==` on nodes is identity: two nodes are equal when they are the same node
of the same tree. Nodes have no order.

| Operation | Type | Result |
|---|---|---|
| `text` | `Node -> String` | the node's source text, decoded as in [String](11-library.md#string) |
| `kind` | `Node -> Kind` | the node's kind |
| `kind_name` | `Node -> String` | the kind's name; an anonymous token's name is its spelling |
| `is_named` | `Node -> Bool` | whether the node is named, not an anonymous token |
| `is_extra` | `Node -> Bool` | whether the node is an extra, such as a comment |
| `range` | `Node -> Range` | the node's extent |
| `filename` | `Node -> Maybe String` | the path of the node's file, or `Nothing` when it has none |

```tql
type Point = {row: Int, column: Int};
type Range = {start_byte: Int, end_byte: Int, start_point: Point, end_point: Point};
```

Offsets count UTF-8 bytes of the source, from 0. A range includes its
start and excludes its end.

## Kinds

A kind literal `:k` names the named node kind `k` of the target grammar,
so `:identifier` names the node kind, not an anonymous token spelled
`identifier`. A kind the grammar does not have is an error,
`unknown-kind`.

`Kind` has `Eq` and `ToJson`. `is_kind k n` tests a node's kind, and
`of_kind k` is the filter that keeps a node of kind `k`:

```tql
is_kind :: Kind -> Node -> Bool;
is_kind k n = kind n == k;

of_kind :: Kind -> Filter Node Node;
of_kind k = Kleisli $ \n -> if is_kind k n then [n] else [];
```

## Fields

`n#f` is the list of `n`'s children in the grammar field `f`, in document
order: empty when `n` has no such child, and every child when the field
repeats. A field the grammar does not have is an error, `unknown-field`.

## Navigation

All navigation is one primitive:

```tql
data Axis
  = Child
  | Descendant
  | Parent
  | Ancestor
  | NextSibling
  | PrevSibling
  | FollowingSibling
  | PrecedingSibling;

data Test
  = Any
  | Named
  | OfKind Kind;

navigate :: Axis -> Test -> Node -> [Node];
```

`navigate a t n` is the nodes on axis `a` from `n` that pass the node test
`t`, in the axis's order. `Any` passes every node, `Named` the named
nodes, and `OfKind k` the nodes of kind `k`.

| Axis | Nodes, in order |
|---|---|
| `Child` | the children, in document order |
| `Descendant` | the descendants, in pre-order, without `n` |
| `Parent` | the parent, or none at the root |
| `Ancestor` | the ancestors, nearest first |
| `NextSibling` | the next sibling, or none |
| `PrevSibling` | the previous sibling, or none |
| `FollowingSibling` | the later siblings, nearest first |
| `PrecedingSibling` | the earlier siblings, nearest first |

Each named axis of the library is `navigate` at one axis and one test,
lifted to a filter:

```tql
descendants_of_kind :: Kind -> Filter Node Node;
descendants_of_kind k = Kleisli $ navigate Descendant $ OfKind k;
```

The axes are lazy: an axis yields its first node without walking the rest,
so `head $ run (descendants_of_kind :k) n` stops at the first match.

## Syntax errors

A file that tree-sitter cannot parse cleanly still has a tree. Where the
parser skipped text, the tree has an `ERROR` node; where it supplied a
token the text lacked, it has a missing node. A missing node matches
patterns as a real one of its kind does, and its text is `""`.

| Operation | Type | Holds of |
|---|---|---|
| `is_error` | `Node -> Bool` | an `ERROR` node |
| `is_missing` | `Node -> Bool` | a missing node |
| `has_error` | `Node -> Bool` | a node that is, or contains, an `ERROR` or missing node |

A program that should skip files with syntax errors says so:

```tql
main = keep (\n -> not $ has_error n) | descendants_of_kind :debugger_statement;
```
