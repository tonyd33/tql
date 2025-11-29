import { absurd } from "fp-ts/lib/function";
import * as Backend from "./backend";
import type * as Frontend from "./frontend";

const desugarCondition = (condition: Frontend.Condition): Backend.Condition => {
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

const desugarStatements = (statements: Frontend.Statement[]) => {
  let descendantAxisQuery = Backend.oneQuery;
  let childAxisQuery = Backend.oneQuery;
  const captures: Backend.Capture[] = [];
  const conditions: Backend.Condition[] = [];
  for (const statement of statements) {
    switch (statement.type) {
      case "query":
        // FIXME: There surely has to be a better way to do this...
        if (
          statement.query.selector.type === "child" &&
          statement.query.selector.parent == null
        ) {
          childAxisQuery = Backend.outerProductQuery(
            childAxisQuery,
            Backend.axisQuery(
              Backend.childAxis,
              // FIXME: This is not right
              desugarSelectorForCaptures(captures)(statement.query.selector.child),
            ),
          );
        } else {
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
        }
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
      case "function-match":
        throw new Error("Not implemented");
      case "lexical-binding-inheritance":
        throw new Error("Not implemented");
      default:
        absurd(statement);
    }
  }
  return { descendantAxisQuery, childAxisQuery, captures, conditions };
};

const desugarSelectorForCaptures =
  (captures: Backend.Capture[]) =>
  (selector: Frontend.Selector): Backend.Query => {
    const desugarSelector = desugarSelectorForCaptures(captures);
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
          selector.parent ? desugarSelector(selector.parent) : Backend.oneQuery,
          Backend.axisQuery(Backend.childAxis, desugarSelector(selector.child)),
        );
      case "descendant":
        return Backend.outerExponentQuery(
          desugarSelector(selector.parent),
          Backend.axisQuery(
            Backend.descendantAxis,
            desugarSelector(selector.child),
          ),
        );
      case "attribute":
        return Backend.nodePredicateQuery(
          Backend.attributePredicate(desugarCondition(selector.condition)),
          captures,
        );
    }
  };

const desugarFunction = (
  frontendFunction: Frontend.TqlFunction,
): Backend.TqlFunction => {
  const { descendantAxisQuery, childAxisQuery, captures, conditions } =
    desugarStatements(frontendFunction.statements);
  // NOTE: Perhaps there's a more elegant way to do this, but this suffices.
  const left = Backend.nodePredicateQuery(
    Backend.attributePredicate(
      conditions.reduce(Backend.andCondition, Backend.trueCondition),
    ),
    captures,
  );
  const right = descendantAxisQuery;

  return {
    identifier: frontendFunction.identifier,
    parameters: frontendFunction.parameters,
    query: Backend.outerExponentQuery(left, right),
  };
};

export const desugar = (frontendQuery: Frontend.Query): Backend.Query => {
  const { descendantAxisQuery, childAxisQuery, captures, conditions } =
    desugarStatements(frontendQuery.statements);

  const desugarSelector = desugarSelectorForCaptures(captures);

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
  const right = descendantAxisQuery
  // const right = Backend.outerProductQuery(descendantAxisQuery, childAxisQuery);

  return Backend.outerExponentQuery(left, right);
};

export const desugarProgram = (
  frontendProgram: Frontend.Program,
): Backend.Program => {
  if (
    frontendProgram.queries.length !== 1 ||
    frontendProgram.queries[0] == null
  ) {
    throw new Error("TODO: Allow multiple queries");
  }

  return {
    functions: frontendProgram.functions.map(desugarFunction),
    main: desugar(frontendProgram.queries[0]),
  };
};
