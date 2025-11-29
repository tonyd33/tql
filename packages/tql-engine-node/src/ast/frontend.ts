import type * as Parser from "tree-sitter";

// TODO: Create a desugared AST

export type TreeSitterNode = Parser.SyntaxNode;

type TODO = null;

export type Program = {
  functions: TqlFunction[];
  queries: Query[];
};

export type TqlFunction = {
  identifier: string;
  parameters: string[];
  query: Query;
};

export type Selector =
  | { type: "universal" }
  | { type: "node-kind"; kind: string }
  | { type: "child"; parent: Selector; child: Selector }
  | { type: "attribute"; selector: Selector; condition: Condition };

export type Expression =
  | { type: "string-literal"; s: string }
  | { type: "attribute-identifier"; identifier: string }
  | { type: "function-call"; identifier: string }
  | { type: "variable"; identifier: string };

export type VariableDeclarator = TODO;

export type FunctionCall = TODO;

export type AttributeRelation = "=" | "!=" | "~";

export type Condition =
  | {
      type: "attribute";
      e1: Expression;
      relation: AttributeRelation;
      e2: Expression;
    }
  | { type: "and"; c1: Condition; c2: Condition }
  | { type: "or"; c1: Condition; c2: Condition };

export type Statement =
  | { type: "query"; query: Query }
  | { type: "lexical-binding"; identifier: string; value: Expression }
  | {
      type: "lexical-binding-inheritance";
      declarator: VariableDeclarator;
      call: FunctionCall;
    }
  | { type: "function-match"; call: FunctionCall }
  | { type: "condition"; condition: Condition };

export type LexicalBindingStatement = { identifier: string; value: Expression };
export type LexicalBindingInheritanceStatement = {
  declarator: VariableDeclarator;
  call: FunctionCall;
};
export type FunctionMatchStatement = { call: FunctionCall };

export type Query = {
  selector: Selector;
  statements: Statement[];
};
