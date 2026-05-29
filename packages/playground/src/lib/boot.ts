import { init, type Engine } from "tql";
import { Parser, Language } from "web-tree-sitter";

export let engine: Engine;

export const ready = (async () => {
  const [e, _] = await Promise.all([
    init({
      compilation: {
        via: "streaming",
        source: fetch("./tql.wasm"),
      },
    }),
    Parser.init(),
  ]);
  engine = e;
})();

const cache = new Map<string, Promise<Language>>();
export function loadLanguage(key: string): Promise<Language> {
  let p = cache.get(key);
  if (!p) {
    p = Language.load(`./tree-sitter-${key}.wasm`);
    cache.set(key, p);
  }
  return p;
}
