import type * as Backend from "./backend";

const explainExpression = (expression: Backend.Expression): string => {
  switch (expression.type) {
    case "string-literal":
      return `'${expression.s}'`;
    case "attribute-identifier":
      return `.${expression.identifier}`;
    case "function-call":
      return `${expression.identifier}()`;
    case "variable":
      return `${expression.identifier}`;
  }
};

const explainCondition = (condition: Backend.Condition): string => {
  switch (condition.type) {
    case "attribute":
      return `${explainExpression(condition.e1)} ${condition.relation} ${explainExpression(condition.e2)}`;
    case "and":
      return `(${explainCondition(condition.c1)} and ${explainCondition(condition.c2)})`;
    case "or":
      return `(${explainCondition(condition.c1)} or ${explainCondition(condition.c2)})`;
    case "true":
      return "true";
    case "false":
      return "false";
  }
};

const explainNodePredicate = (nodePredicate: Backend.NodePredicate): string => {
  switch (nodePredicate.type) {
    case "universal":
      return "always";
    case "node-kind":
      return `nodes of type ${nodePredicate.kind}`;
    case "attribute":
      return `condition ${explainCondition(nodePredicate.condition)} holds`;
  }
};

export const explainQuery = (query: Backend.Query): string => {
  switch (query.type) {
    case "zero":
      return "matches nothing";
    case "one":
      return "matching the same thing";
    case "node-predicate":
      return `${explainNodePredicate(query.predicate)}`;
    case "outer-sum":
      return `matching (${explainQuery(query.left)} or ${explainQuery(query.right)})`;
    case "outer-product":
      return `matching (${explainQuery(query.left)} x ${explainQuery(query.right)})`;
    case "outer-exponent":
      return `every match (${explainQuery(query.left)} => ${explainQuery(query.right)})`;
    case "axis":
      return `every (${query.axis.type} matches ${explainQuery(query.q)})`;
  }
};
