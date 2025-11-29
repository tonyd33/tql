import { assert } from "chai";
import type * as TS from "../../tree-sitter";
import * as Core from "../core";
import * as Tree from ".";

const ast1: TS.Node = {
  id: 0,
  typeId: 0,
  type: "root",
  text: "",
  namedChildren: [
    {
      id: 1,
      typeId: 1,
      type: "class_declaration",
      text: "",
      namedChildren: [
        {
          id: 2,
          typeId: 2,
          type: "decorator",
          text: "",
          namedChildren: [],
        },
      ],
    },
  ],
};

const ast2: TS.Node = {
  id: 0,
  typeId: 0,
  type: "root",
  text: "",
  namedChildren: [
    {
      id: 1,
      typeId: 1,
      type: "class_declaration",
      text: "",
      namedChildren: [
        {
          id: 2,
          typeId: 2,
          type: "decorator",
          text: "Controller",
          namedChildren: [],
        },
      ],
    },
  ],
};

it("runs children", () => {
  const query = [
    Tree.children,
    Core.predicate((n: TS.Node) => n.type === "class_declaration"),
    Tree.children,
    Core.predicate((n: TS.Node) => n.type === "decorator"),
  ].reduce(Core.kleisli, x => [x]);
  const results = Core.runPath([ast1], query);
  assert.deepEqual(results, [
    { namedChildren: [], id: 2, text: "", type: "decorator", typeId: 2 },
  ]);
});

it("runs descendants", () => {
  const query = [
    Tree.descendant,
    Core.predicate((n: TS.Node) => n.type === "decorator"),
  ].reduce(Core.kleisli, x => [x]);
  const results = Core.runPath([ast1], query);
  assert.deepEqual(results, [
    { namedChildren: [], id: 2, text: "", type: "decorator", typeId: 2 },
  ]);
});
