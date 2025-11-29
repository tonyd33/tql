import * as TS from "../../tree-sitter";
import type { Step } from "../core";

export const children: Step<TS.Node> = TS.children;
export const descendant: Step<TS.Node> = n => {
  const go: Step<TS.Node> = (m: TS.Node) => {
    const direct = TS.children(m);
    const indirect = TS.children(m).flatMap(go);
    return [...direct, ...indirect];
  };
  return go(n);
};
