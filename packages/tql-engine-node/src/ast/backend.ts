import type * as TS from "../tree-sitter";

/**
 * This file contains interfaces for the backend representation of TQL queries.
 * It may be likened to think of this as the barebones intermediate
 * representation to produce a program capable of running queries.
 */

export type AttributeRelation = "=" | "!=" | "~";

export type Expression =
  | { type: "string-literal"; s: string }
  | { type: "attribute-identifier"; identifier: string }
  | { type: "function-call"; identifier: string }
  | { type: "variable"; identifier: string };
export const stringLiteralExpression = (s: string): Expression => ({
  type: "string-literal",
  s,
});
export const attributeIdentifierExpression = (
  identifier: string,
): Expression => ({
  type: "attribute-identifier",
  identifier,
});
export const functionCallExpression = (identifier: string): Expression => ({
  type: "function-call",
  identifier,
});

export type Value =
  | { type: "nothing" }
  | { type: "string"; value: string }
  | { type: "node"; value: TS.Node }
  | { type: "position"; value: { line: number; column: number } };
export const nothingValue: Value = { type: "nothing" };
export const stringValue = (value: string): Value => ({
  type: "string",
  value,
});
export const nodeValue = (value: TS.Node): Value => ({
  type: "node",
  value,
});
export const positionValue = (value: {
  line: number;
  column: number;
}): Value => ({
  type: "position",
  value,
});
export const valueEq = (v1: Value, v2: Value): boolean => {
  if (v1.type !== v2.type) {
    return false;
  } else if (v1.type === "nothing" || v2.type === "nothing") {
    // both v1 and v2 are nothing
    return true;
  } else {
    // FIXME: This doesn't work for non-scalars.
    return v1.value === v2.value;
  }
};

export type Condition =
  | {
      type: "attribute";
      e1: Expression;
      relation: AttributeRelation;
      e2: Expression;
    }
  | { type: "and"; c1: Condition; c2: Condition }
  | { type: "or"; c1: Condition; c2: Condition }
  | { type: "true" }
  | { type: "false" };
export const attributeCondition = (
  e1: Expression,
  relation: AttributeRelation,
  e2: Expression,
): Condition => ({
  type: "attribute",
  e1,
  relation,
  e2,
});
export const andCondition = (c1: Condition, c2: Condition): Condition => ({
  type: "and",
  c1,
  c2,
});
export const orCondition = (c1: Condition, c2: Condition): Condition => ({
  type: "or",
  c1,
  c2,
});
export const trueCondition: Condition = { type: "true" };
export const falseCondition: Condition = { type: "false" };

export type Capture = { identifier: string; expression: Expression };

export type NodePredicate =
  | { type: "universal" }
  | { type: "node-kind"; kind: string }
  | { type: "attribute"; condition: Condition };
export const universalPredicate: NodePredicate = { type: "universal" };
export const nodeKindPredicate = (kind: string): NodePredicate => ({
  type: "node-kind",
  kind,
});
export const attributePredicate = (condition: Condition): NodePredicate => ({
  type: "attribute",
  condition,
});

export type Axis = { type: "child" } | { type: "descendant" };
export const childAxis: Axis = { type: "child" };
export const descendantAxis: Axis = { type: "descendant" };

/**
 * A query describes a way to traverse the tree to match nodes.
 *
 * Queries are realized with a function
 * `runQuery:: Query -> (Node, Env) -> (Node, Env)[]`,
 * which interprets the query on a tree rooted at a node under an environment
 * and produces a resulting set of node, environment pairs.
 *
 * The pair `(Node, Env)` will henceforth be referred to as a `Match`.
 *
 * The following union types define an algebra on queries.
 */
export type Query =
  /**
   * `runQuery q match` will always produce no matches.
   */
  | { type: "zero" }
  /**
   * `runQuery q match` will always produce a single match `match`.
   */
  | { type: "one" }
  /**
   * `runQuery (predicate, captures) (node, env)` will test
   * the `predicate` on `node`.
   *
   * If the predicate succeeds, the query will capture variables into `env`
   * to produce `env'` and we will return a result set of `(node, env')`.
   */
  | {
      type: "node-predicate";
      predicate: NodePredicate;
      captures: Capture[];
    }
  /**
   * `runQuery (left, right) match@(node)` will find the return the result of
   * `runQuery left match` concatenated with the result of
   * `runQuery right match`, with the node of each result replaced with `node`.
   */
  | { type: "outer-sum"; left: Query; right: Query }
  /**
   * `runQuery (q1, q2) match` will run `matches1 <- runQuery q1 match` and
   * `matches2 <- runQuery q2 match` and return the cartesian product of `matches1`
   * and `matches2`, with the node of each result replaced with `node`.
   */
  | { type: "outer-product"; left: Query; right: Query }
  /**
   * `runQuery (q1, q2) match` will run `matches1 <- runQuery q1 match` and
   * for every `match1` of `matches1`, it will return the flattened set of
   * `runQuery q2 match1`.
   */
  | { type: "outer-exponent"; left: Query; right: Query }
  /**
   * `runQuery (axis, q) match@(node, env)` return a set of results
   * `runQuery q (node', env)` for each `node'` along the axis of `node`.
   */
  | { type: "axis"; axis: Axis; q: Query };
export const zeroQuery: Query = { type: "zero" };
export const oneQuery: Query = { type: "one" };
export const nodePredicateQuery = (
  predicate: NodePredicate,
  captures: Capture[],
): Query => ({ type: "node-predicate", predicate, captures });
export const outerSumQuery = (left: Query, right: Query): Query => ({
  type: "outer-sum",
  left,
  right,
});
export const outerProductQuery = (left: Query, right: Query): Query => ({
  type: "outer-product",
  left,
  right,
});
export const outerExponentQuery = (left: Query, right: Query): Query => ({
  type: "outer-exponent",
  left,
  right,
});
export const axisQuery = (axis: Axis, q: Query): Query => ({
  type: "axis",
  axis,
  q,
});
