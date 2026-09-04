import { init, grammars, type Engine, type GrammarInfo } from "tql";
import { Parser, Language } from "web-tree-sitter";

const withParserWasm = new Set([
  "bash",
  "c",
  "c_sharp",
  "cpp",
  "css",
  "elixir",
  "go",
  "haskell",
  "html",
  "java",
  "javascript",
  "json",
  "kotlin",
  "lua",
  "make",
  "nix",
  "ocaml",
  "php",
  "python",
  "ruby",
  "rust",
  "scala",
  "toml",
  "tsx",
  "typescript",
  "zig",
]);

export const availableGrammars: readonly GrammarInfo[] = grammars.filter((g) =>
  withParserWasm.has(g.key),
);

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
