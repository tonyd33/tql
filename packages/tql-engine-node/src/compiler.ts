import { pipe } from "fp-ts/lib/function";
import type { Backend } from "./ast";
import type { Expression, Query, Statement } from "./ast/frontend";
import * as T from "./traversal";
import type * as TS from "./tree-sitter";

type Capturer = (
  c: T.Capture.Captured<TS.Node, string>,
) => T.Capture.Captures<string>;

const emptyCapturer: Capturer = (_) => ({});

const evaluateExpression = (
  e: Expression,
  n: TS.Node,
  c: T.Capture.Captures<string>,
): string | undefined => {
  switch (e.type) {
    case "string-literal":
      return e.s;
    case "attribute-identifier":
      // TODO: Implement not bad
      return e.identifier in n
        ? (n[e.identifier as keyof TS.Node] as string)
        : undefined;
    case "function-call":
      // TODO: Implement
      return undefined;
  }
};

const captureStatement = (s: Statement): Capturer => {
  switch (s.type) {
    case "lexical-binding":
      return ({ value, captures }) => {
        const resolved = evaluateExpression(s.value, value, captures);
        return resolved != null ? { [s.identifier]: resolved } : {};
      };
    default:
      return emptyCapturer;
  }
};

const joinCapture =
  (c1: Capturer, c2: Capturer): Capturer =>
  (c) => ({
    ...c1(c),
    ...c2(c),
  });

export const compileQuery = (
  query: Query,
): T.Capture.CapturedStep<TS.Node, string> => {
  const { selector, statements } = query;
  switch (selector.type) {
    case "node-kind":
      return T.Core.compose(
        T.TreeCapture.descendant,
        pipe(
          T.Core.predicate((n: TS.Node) => n.type === selector.kind),
          T.Capture.bindWith2(
            statements.map(captureStatement).reduce(joinCapture, emptyCapturer),
          ),
        ),
      );
    case "universal":
    case "child":
    case "attribute":
      throw new Error("Not implemented");
  }
};

type CompiledStep = T.Capture.CapturedStep<TS.Node, string>;

const matchNode = (
  matcher: Backend.NodePredicate,
): ((n: TS.Node) => boolean) => {
  switch (matcher.type) {
    case "universal":
      return () => true;
    case "node-kind":
      return (n) => {
        // console.log(n);
        return n.type === matcher.kind;
      };
    case "attribute":
      throw new Error("Not implemented");
  }
};

const bind =
  (bindings: Backend.Capture[]): Capturer =>
  ({ value, captures }) =>
    Object.fromEntries(
      bindings.map(({ identifier, expression }) => [
        identifier,
        evaluateExpression(expression, value, captures) ?? "Bad",
      ]),
    );

const compileBackendSubquery = (sq: Backend.Subquery): CompiledStep => {
  switch (sq.type) {
    case "empty":
      return (n) => [n];
    case "or":
      return T.TreeCapture.outerExponent(
        compileBackendSubquery(sq.sq1),
        compileBackendSubquery(sq.sq2),
      );
    case "and":
      return T.TreeCapture.outerProduct(
        compileBackendSubquery(sq.sq1),
        compileBackendSubquery(sq.sq2),
      );
    case "child":
      return T.Core.compose(
        T.TreeCapture.children,
        compileBackendQuery(sq.query),
      );
    case "descendant":
      return T.Core.compose(
        T.TreeCapture.descendant,
        compileBackendQuery(sq.query),
      );
  }
};

export const compileBackendQuery = (query: Backend.Query): CompiledStep => {
  switch (query.matcher.type) {
    case "node-kind":
      return T.TreeCapture.outerProduct(
        pipe(
          T.Core.predicate(matchNode(query.matcher)),
          T.Capture.bindWith2(bind(query.bindings)),
        ),
        compileBackendSubquery(query.subs),
      );
    case "universal":
    case "attribute":
      throw new Error("Not implemented");
  }
};
