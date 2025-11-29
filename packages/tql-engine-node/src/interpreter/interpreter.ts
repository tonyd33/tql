import * as Tql from "../ast";
import * as T from "../traversal";
import type * as TS from "../tree-sitter";

type InterpretedMatch = T.Capture.Captured<TS.Node, Tql.Backend.Value>;
type InterpretedStep = T.Capture.CapturedStep<TS.Node, Tql.Backend.Value>;
type InterpretedPredicate = (m: InterpretedMatch) => boolean;
type InterpretedCapturer = (m: InterpretedMatch) => InterpretedMatch[];

const evaluateExpression = (
  expr: Tql.Backend.Expression,
  m: InterpretedMatch,
): Tql.Backend.Value => {
  switch (expr.type) {
    case "string-literal":
      return Tql.Backend.stringValue(expr.s);
    case "attribute-identifier": {
      switch (expr.identifier) {
        case "text":
          return Tql.Backend.stringValue(m.value.text);
        default:
          throw new Error("Not implemented");
      }
    }
    case "variable": {
      const value = m.captures[expr.identifier];
      if (value != null) {
        return value;
      } else {
        return Tql.Backend.nothingValue;
      }
    }
    case "function-call":
      throw new Error("Not implemented");
  }
};

const interpretCondition = (c: Tql.Backend.Condition): InterpretedPredicate => {
  switch (c.type) {
    case "attribute":
      return m => {
        const v1 = evaluateExpression(c.e1, m);
        const v2 = evaluateExpression(c.e2, m);
        switch (c.relation) {
          case "=":
            return Tql.Backend.valueEq(v1, v2);
          case "!=":
            return !Tql.Backend.valueEq(v1, v2);
          case "~":
            throw new Error("Not implemented");
        }
      };
    case "or": {
      const p1 = interpretCondition(c.c1);
      const p2 = interpretCondition(c.c2);
      return m => p1(m) || p2(m);
    }
    case "and": {
      const p1 = interpretCondition(c.c1);
      const p2 = interpretCondition(c.c2);
      return m => p1(m) && p2(m);
    }
    case "true":
      return _ => true;
    case "false":
      return _ => false;
  }
};

const interpretPredicate = (
  p: Tql.Backend.NodePredicate,
): InterpretedPredicate => {
  switch (p.type) {
    case "universal":
      return _ => true;
    case "node-kind":
      return ({ value }) => value.type === p.kind;
    case "attribute": {
      const c = interpretCondition(p.condition);
      return c;
    }
  }
};

const interpretCapture =
  (cs: Tql.Backend.Capture[]): InterpretedCapturer =>
  m => {
    return [
      {
        value: m.value,
        captures: {
          ...m.captures,
          ...Object.fromEntries(
            cs.map(({ identifier, expression }) => [
              identifier,
              evaluateExpression(expression, m),
            ]),
          ),
        },
      },
    ];
  };

export const interpret = (q: Tql.Backend.Query): InterpretedStep => {
  switch (q.type) {
    case "zero":
      return _ => [];
    case "one":
      return m => [m];
    case "node-predicate": {
      const pred = interpretPredicate(q.predicate);
      const capture = interpretCapture(q.captures);
      return m => (pred(m) ? capture(m) : []);
    }
    case "outer-sum":
      return T.TreeCapture.outerSum(interpret(q.left), interpret(q.right));
    case "outer-product":
      return T.TreeCapture.outerProduct(interpret(q.left), interpret(q.right));
    case "outer-exponent":
      return T.TreeCapture.outerExponent(interpret(q.left), interpret(q.right));
    case "axis":
      switch (q.axis.type) {
        case "child":
          return T.Core.compose(T.TreeCapture.children, interpret(q.q));
        case "descendant":
          return T.Core.compose(T.TreeCapture.descendant, interpret(q.q));
      }
  }
};
