import { absurd } from "fp-ts/lib/function";
import * as Backend from "./backend";
import type * as Frontend from "./frontend";

export const desugar = (frontendQuery: Frontend.Query): Backend.Query => {
  const desugarCondition = (
    condition: Frontend.Condition,
  ): Backend.Condition => {
    switch (condition.type) {
      case "attribute":
        return Backend.attributeCondition(
          condition.e1,
          condition.relation,
          condition.e2,
        );
      case "or":
        return Backend.orCondition(condition.c1, condition.c2);
      case "and":
        return Backend.andCondition(condition.c1, condition.c2);
    }
  };

  let descendantAxisQuery = Backend.oneQuery;
  const captures: Backend.Capture[] = [];
  const conditions: Backend.Condition[] = [];
  for (const statement of frontendQuery.statements) {
    switch (statement.type) {
      case "query":
        // NOTE: This is horribly inefficient. We traverse the descendants for
        // every single subquery!
        // We should be able to combine these tree walks... possibly by simply
        // taking the outer product without applying the descendant axis and
        // then taking the outer product...?
        // Or perhaps, we need to introduce a new operator
        descendantAxisQuery = Backend.outerProductQuery(
          descendantAxisQuery,
          Backend.axisQuery(Backend.descendantAxis, desugar(statement.query)),
        );
        break;
      case "lexical-binding":
        captures.push({
          identifier: statement.identifier,
          expression: statement.value,
        });
        break;
      case "condition":
        conditions.push(desugarCondition(statement.condition));
        break;
      case "lexical-binding-inheritance":
      case "function-match":
        throw new Error("Not implemented");
      default:
        absurd(statement);
    }
  }

  const desugarSelector = (selector: Frontend.Selector): Backend.Query => {
    switch (selector.type) {
      case "universal":
        return Backend.nodePredicateQuery(Backend.universalPredicate, captures);
      case "node-kind":
        return Backend.nodePredicateQuery(
          Backend.nodeKindPredicate(selector.kind),
          captures,
        );
      case "child":
        return Backend.outerExponentQuery(
          desugarSelector(selector.parent),
          Backend.axisQuery(Backend.childAxis, desugarSelector(selector.child)),
        );
      case "attribute":
        return Backend.nodePredicateQuery(
          Backend.attributePredicate(desugarCondition(selector.condition)),
          captures,
        );
    }
  };

  // NOTE: Perhaps there's a more elegant way to do this, but this suffices.
  const left = Backend.outerExponentQuery(
    desugarSelector(frontendQuery.selector),
    Backend.nodePredicateQuery(
      Backend.attributePredicate(
        conditions.reduce(Backend.andCondition, Backend.trueCondition),
      ),
      captures,
    ),
  );
  const right = descendantAxisQuery;

  return Backend.outerExponentQuery(left, right);
};
