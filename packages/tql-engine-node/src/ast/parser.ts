import * as assert from "node:assert";
import * as Parser from "tree-sitter";
import * as Tql from "tree-sitter-tql";
import type * as Frontend from "./frontend";

class ParseError extends Error {}

const unwrap = <T>(x: T | null | undefined): T => {
  if (x == null) {
    throw new ParseError("Bad program");
  }
  return x;
};

const parseRelation = (node: Parser.SyntaxNode): Frontend.AttributeRelation => {
  switch (node.text) {
    case "=":
    case "!=":
    case "~":
      return node.text;
  }
  throw new ParseError(`parseRelation not implemented ${node.toString()}`);
};

const parseCondition = (node: Parser.SyntaxNode): Frontend.Condition => {
  switch (node.type) {
    case "attribute_condition":
      return {
        type: "attribute",
        e1: parseExpression(unwrap(node.childForFieldName("expression_1"))),
        relation: parseRelation(unwrap(node.childForFieldName("relation"))),
        e2: parseExpression(unwrap(node.childForFieldName("expression_2"))),
      };
    case "or_condition":
      return {
        type: "or",
        c1: parseCondition(unwrap(node.childForFieldName("condition_1"))),
        c2: parseCondition(unwrap(node.childForFieldName("condition_2"))),
      };
    case "and_condition":
      return {
        type: "and",
        c1: parseCondition(unwrap(node.childForFieldName("condition_1"))),
        c2: parseCondition(unwrap(node.childForFieldName("condition_2"))),
      };
  }
  throw new ParseError(
    `parseCondition not implemented ${node.type} ${node.toString()}`,
  );
};

const parseSelector = (node: Parser.SyntaxNode): Frontend.Selector => {
  switch (node.type) {
    case "universal_selector":
      return { type: "universal" };
    case "node_kind_identifier":
      return { type: "node-kind", kind: node.text };
    case "child_selector":
      return {
        type: "child",
        parent: parseSelector(unwrap(node.childForFieldName("parent"))),
        child: parseSelector(unwrap(node.childForFieldName("child"))),
      };
    case "attribute_selector": {
      return {
        type: "attribute",
        selector: parseSelector(unwrap(node.childForFieldName("selector"))),
        condition: parseCondition(unwrap(node.childForFieldName("condition"))),
      };
    }
  }
  throw new ParseError(`parseSelector not implemented ${node.toString()}`);
};

const parseExpression = (node: Parser.SyntaxNode): Frontend.Expression => {
  switch (node.type) {
    case "attribute_identifier":
      return {
        type: "attribute-identifier",
        identifier: unwrap(node.childForFieldName("identifier")).text,
      };
    case "string_literal":
      return {
        type: "string-literal",
        s: unwrap(node.childForFieldName("content")).text,
      };
    case "variable":
      return {
        type: "variable",
        identifier: node.text,
      };
  }
  throw new ParseError(`parseExpresssion not implemented ${node.toString()}`);
};

const parseStatement = (node: Parser.SyntaxNode): Frontend.Statement => {
  switch (node.type) {
    case "comment":
      // TODO: Maybe preserve comments in the AST?
      break;
    case "lexical_binding": {
      const identifier = unwrap(node.childForFieldName("identifier"));
      const value = unwrap(node.childForFieldName("value"));
      return {
        type: "lexical-binding",
        identifier: identifier.text,
        value: parseExpression(value),
      };
    }
    case "query":
      return { type: "query", query: parseQuery(node) };
    case "condition":
      return {
        type: "condition",
        condition: parseCondition(unwrap(node.childForFieldName("condition"))),
      };
  }
  throw new ParseError(
    `parseStatement not implemented ${node.type} ${node.toString()}`,
  );
};

const parseQuery = (node: Parser.SyntaxNode): Frontend.Query => {
  assert.strictEqual(node.type, "query");
  const selector = unwrap(node.childForFieldName("selector"));
  const statements = node.childrenForFieldName("statement");
  const frontendSelector = parseSelector(selector);
  const frontendStatements = statements.map(parseStatement);
  return { selector: frontendSelector, statements: frontendStatements };
};

export const parseTql = (buf: string): Frontend.Query => {
  const tqlParser = new Parser();
  tqlParser.setLanguage(Tql as Parser.Language);
  const tsTqlTree = tqlParser.parse(buf);
  const main = tsTqlTree.rootNode.firstNamedChild;
  if (main == null) {
    throw new ParseError("Bad program");
  }
  return parseQuery(main);
};
