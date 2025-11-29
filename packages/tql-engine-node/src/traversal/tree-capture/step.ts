import type * as TS from "../../tree-sitter";
import * as Capture from "../capture";
import * as Core from "../core";
import * as Tree from "../tree";

export const children = Capture.bind(Tree.children);
export const descendant = Capture.bind(Tree.descendant);

export const outerSum =
  <B>(
    left: Capture.CapturedStep<TS.Node, B>,
    right: Capture.CapturedStep<TS.Node, B>,
  ): Capture.CapturedStep<TS.Node, B> =>
  (s) => {
    const lefts = Core.runPath([s], left);
    const rights = Core.runPath([s], right);
    return [...lefts, ...rights];
  };

export const outerProduct =
  <B>(
    left: Capture.CapturedStep<TS.Node, B>,
    right: Capture.CapturedStep<TS.Node, B>,
  ): Capture.CapturedStep<TS.Node, B> =>
  (s) => {
    const lefts = Core.runPath([s], left);
    const rights = Core.runPath([s], right);
    return lefts.flatMap((l) =>
      rights.flatMap((r) => ({
        value: s.value,
        captures: Capture.sum(l.captures, r.captures),
      })),
    );
  };

export const outerExponent = <B>(
  left: Capture.CapturedStep<TS.Node, B>,
  right: Capture.CapturedStep<TS.Node, B>,
): Capture.CapturedStep<TS.Node, B> => Core.compose(left, right);
