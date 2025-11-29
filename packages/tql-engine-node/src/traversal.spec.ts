import { assert } from "chai";
import { pipe } from "fp-ts/lib/function";
import * as T from "./traversal";
import type * as TS from "./tree-sitter";

it("binds", () => {
  const ast: TS.Node = {
    id: 0,
    typeId: 0,
    type: "root",
    text: "",
    children: [
      {
        id: 1,
        typeId: 1,
        type: "class_declaration",
        text: "MyClass",
        children: [
          {
            id: 2,
            typeId: 2,
            type: "decorator",
            text: "Controller",
            children: [],
          },
        ],
      },
    ],
  };

  const query = T.Core.compose(
    pipe(T.Tree.children, T.Capture.bind),
    pipe(
      T.Core.predicate((n: TS.Node) => n.type === "class_declaration"),
      T.Capture.bindWith((n: TS.Node) => ({ class_name: n.text })),
    ),
    T.TreeCapture.children,
    pipe(
      T.Core.predicate((n: TS.Node) => n.type === "decorator"),
      T.Capture.bindWith((n: TS.Node) => ({ decorator: n.text })),
    ),
  );
  const results = T.Core.runPath([T.Capture.lift(ast)], query);
  assert.deepEqual(
    results.map(({ value }) => value),
    [
      {
        children: [],
        id: 2,
        text: "Controller",
        type: "decorator",
        typeId: 2,
      },
    ],
  );
  assert.deepEqual(
    results.flatMap(({ captures }) => captures),
    [{ class_name: "MyClass", decorator: "Controller" }],
  );
});

it("selectively binds", () => {
  const ast: TS.Node = {
    id: 0,
    typeId: 0,
    type: "root",
    text: "",
    children: [
      {
        id: 1,
        typeId: 1,
        type: "class_declaration",
        text: "MyClass",
        children: [
          {
            id: 2,
            typeId: 2,
            type: "decorator",
            text: "NotController",
            children: [],
          },
        ],
      },
    ],
  };
  const query = T.Core.compose(
    pipe(T.Tree.children, T.Capture.bind),
    pipe(
      T.Core.predicate((n: TS.Node) => n.type === "class_declaration"),
      T.Capture.bindWith((n: TS.Node) => ({ class_name: n.text })),
    ),
    T.TreeCapture.children,
    pipe(
      T.Core.predicate(
        (n: TS.Node) => n.type === "decorator" && n.text === "Controller",
      ),
      T.Capture.bindWith((n: TS.Node) => ({ decorator: n.text })),
    ),
  );
  const results = T.Core.runPath([T.Capture.lift(ast)], query);
  assert.deepEqual(results, []);
});

it("substep", () => {
  const ast: TS.Node = {
    id: 0,
    typeId: 0,
    type: "root",
    text: "",
    children: [
      {
        id: 1,
        typeId: 1,
        type: "class_declaration",
        text: "MyClass",
        children: [
          {
            id: 2,
            typeId: 2,
            type: "decorator",
            text: "Controller",
            children: [],
          },
          {
            id: 2,
            typeId: 2,
            type: "decorator",
            text: "Service",
            children: [],
          },
        ],
      },
    ],
  };
  const query = T.Core.compose(
    pipe(T.Tree.children, T.Capture.bind),
    T.TreeCapture.outerProduct(
      pipe(
        T.Core.predicate((n: TS.Node) => n.type === "class_declaration"),
        T.Capture.bindWith((n: TS.Node) => ({ class_name: n.text })),
      ),
      T.Core.compose(
        T.TreeCapture.children,
        pipe(
          T.Core.predicate(
            (n: TS.Node) =>
              n.type === "decorator" &&
              (n.text === "Controller" || n.text === "Service"),
          ),
          T.Capture.bindWith((n: TS.Node) => ({ decorator: n.text })),
        ),
      ),
    ),
  );
  const results = T.Core.runPath([T.Capture.lift(ast)], query);
  assert.deepEqual(
    results.flatMap(({ captures }) => captures),
    [
      { class_name: "MyClass", decorator: "Controller" },
      { class_name: "MyClass", decorator: "Service" },
    ],
  );
});
