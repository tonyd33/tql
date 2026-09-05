import { init, grammars, type Engine, type GrammarInfo, type Grammar } from "tql";

export const availableGrammars: readonly GrammarInfo[] = grammars;

export let engine: Engine;

export const ready = (async () => {
  engine = await init({
    compilation: {
      via: "streaming",
      source: fetch("./tql.wasm"),
    },
    grammarSource: (name) => ({
      via: "streaming",
      source: fetch(`./tree-sitter-${name}.wasm`),
    }),
  });
})();

export function loadLanguage(key: string): Promise<Grammar> {
  return engine.loadGrammar(key);
}
