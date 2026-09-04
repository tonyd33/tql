import { type Fd, WASI } from "@bjorn3/browser_wasi_shim";

export enum Grammar {
  bash = 0,
  cmake = 1,
  cpp = 2,
  c = 3,
  c_sharp = 4,
  css = 5,
  dockerfile = 6,
  elixir = 7,
  erlang = 8,
  go = 9,
  graphql = 10,
  haskell = 11,
  hcl = 12,
  html = 13,
  java = 14,
  javascript = 15,
  json = 16,
  kotlin = 17,
  lua = 18,
  make = 19,
  markdown = 20,
  nix = 21,
  ocaml = 22,
  php = 23,
  python = 24,
  ruby = 25,
  rust = 26,
  scala = 27,
  solidity = 28,
  toml = 29,
  typescript = 30,
  tsx = 31,
  vue = 32,
  yaml = 33,
  zig = 34,
}

export interface GrammarInfo {
  id: Grammar;
  key: keyof typeof Grammar;
  displayName: string;
}

export const grammars: readonly GrammarInfo[] = [
  { id: Grammar.bash, key: "bash", displayName: "Bash" },
  { id: Grammar.cmake, key: "cmake", displayName: "CMake" },
  { id: Grammar.cpp, key: "cpp", displayName: "C++" },
  { id: Grammar.c, key: "c", displayName: "C" },
  { id: Grammar.c_sharp, key: "c_sharp", displayName: "C#" },
  { id: Grammar.css, key: "css", displayName: "CSS" },
  { id: Grammar.dockerfile, key: "dockerfile", displayName: "Dockerfile" },
  { id: Grammar.elixir, key: "elixir", displayName: "Elixir" },
  { id: Grammar.erlang, key: "erlang", displayName: "Erlang" },
  { id: Grammar.go, key: "go", displayName: "Go" },
  { id: Grammar.graphql, key: "graphql", displayName: "GraphQL" },
  { id: Grammar.haskell, key: "haskell", displayName: "Haskell" },
  { id: Grammar.hcl, key: "hcl", displayName: "HCL" },
  { id: Grammar.html, key: "html", displayName: "HTML" },
  { id: Grammar.java, key: "java", displayName: "Java" },
  { id: Grammar.javascript, key: "javascript", displayName: "JavaScript" },
  { id: Grammar.json, key: "json", displayName: "JSON" },
  { id: Grammar.kotlin, key: "kotlin", displayName: "Kotlin" },
  { id: Grammar.lua, key: "lua", displayName: "Lua" },
  { id: Grammar.make, key: "make", displayName: "Make" },
  { id: Grammar.markdown, key: "markdown", displayName: "Markdown" },
  { id: Grammar.nix, key: "nix", displayName: "Nix" },
  { id: Grammar.ocaml, key: "ocaml", displayName: "OCaml" },
  { id: Grammar.php, key: "php", displayName: "PHP" },
  { id: Grammar.python, key: "python", displayName: "Python" },
  { id: Grammar.ruby, key: "ruby", displayName: "Ruby" },
  { id: Grammar.rust, key: "rust", displayName: "Rust" },
  { id: Grammar.scala, key: "scala", displayName: "Scala" },
  { id: Grammar.solidity, key: "solidity", displayName: "Solidity" },
  { id: Grammar.toml, key: "toml", displayName: "TOML" },
  { id: Grammar.typescript, key: "typescript", displayName: "TypeScript" },
  { id: Grammar.tsx, key: "tsx", displayName: "TSX" },
  { id: Grammar.vue, key: "vue", displayName: "Vue" },
  { id: Grammar.yaml, key: "yaml", displayName: "YAML" },
  { id: Grammar.zig, key: "zig", displayName: "Zig" },
] as const;

export interface QueryArgs {
  querySource: string;
  queryTarget: string;
  grammar: Grammar;
}

export interface QueryStats {
  parse_time_ns: number;
  query_time_ns: number;
}

export interface QueryResult {
  values: unknown[];
  stats: QueryStats;
}

export interface Engine {
  query(args: QueryArgs): QueryResult;
  grammarNames(): string[];
}

type CompileOptions =
  | { via: "streaming"; source: Response | PromiseLike<Response> }
  | { via: "buffer"; buffer: BufferSource };

export type Options = {
  compilation: CompileOptions;
};

interface WasmExports {
  memory: WebAssembly.Memory;
  tql_alloc(len: number): number;
  tql_free(ptr: number, len: number): void;
  tql_grammars(outPtr: number): void;
  tql_run(
    language: number,
    queryPtr: number,
    queryLen: number,
    targetPtr: number,
    targetLen: number,
    outPtr: number,
  ): void;
}

const RESULT_SIZE = 12;

async function compile(options: CompileOptions): Promise<WebAssembly.Module> {
  switch (options.via) {
    case "streaming":
      return WebAssembly.compileStreaming(options.source);
    case "buffer":
      return WebAssembly.compile(options.buffer);
  }
}

class TqlEngine implements Engine {
  private readonly encoder = new TextEncoder();
  private readonly decoder = new TextDecoder();

  constructor(private readonly exp: WasmExports) {}

  query(args: QueryArgs): QueryResult {
    const { exp } = this;
    const query = this.writeStr(args.querySource);
    const target = this.writeStr(args.queryTarget);
    const outPtr = exp.tql_alloc(RESULT_SIZE);
    if (outPtr === 0) {
      exp.tql_free(query.ptr, query.len);
      exp.tql_free(target.ptr, target.len);
      throw new Error("tql_alloc failed");
    }

    try {
      exp.tql_run(
        args.grammar,
        query.ptr,
        query.len,
        target.ptr,
        target.len,
        outPtr,
      );
      const view = new DataView(exp.memory.buffer, outPtr, RESULT_SIZE);
      const status = view.getInt32(0, true);
      const dataPtr = view.getUint32(4, true);
      const dataLen = view.getUint32(8, true);

      if (dataLen === 0 && status !== 0) {
        throw new Error("tql_run failed");
      }

      const bytes = new Uint8Array(exp.memory.buffer, dataPtr, dataLen).slice();
      exp.tql_free(dataPtr, dataLen);
      const text = this.decoder.decode(bytes);

      if (status !== 0) throw new Error(text);
      return JSON.parse(text) as QueryResult;
    } finally {
      exp.tql_free(query.ptr, query.len);
      exp.tql_free(target.ptr, target.len);
      exp.tql_free(outPtr, RESULT_SIZE);
    }
  }

  grammarNames(): string[] {
    const { exp } = this;
    const outPtr = exp.tql_alloc(RESULT_SIZE);
    if (outPtr === 0) throw new Error("tql_alloc failed");
    try {
      exp.tql_grammars(outPtr);
      const view = new DataView(exp.memory.buffer, outPtr, RESULT_SIZE);
      const status = view.getInt32(0, true);
      const dataPtr = view.getUint32(4, true);
      const dataLen = view.getUint32(8, true);
      if (status !== 0) throw new Error("tql_grammars failed");
      const bytes = new Uint8Array(exp.memory.buffer, dataPtr, dataLen).slice();
      exp.tql_free(dataPtr, dataLen);
      return JSON.parse(this.decoder.decode(bytes)) as string[];
    } finally {
      exp.tql_free(outPtr, RESULT_SIZE);
    }
  }

  private writeStr(s: string): { ptr: number; len: number } {
    const buf = this.encoder.encode(s);
    const ptr = this.exp.tql_alloc(buf.length);
    if (ptr === 0 && buf.length !== 0) throw new Error("tql_alloc failed");
    new Uint8Array(this.exp.memory.buffer, ptr, buf.length).set(buf);
    return { ptr, len: buf.length };
  }
}

export async function init(options: Options): Promise<Engine> {
  const args: string[] = [];
  const env: string[] = [];
  const fds: Fd[] = [];

  const wasi = new WASI(args, env, fds);
  const wasm = await compile(options.compilation);
  const instance = await WebAssembly.instantiate(wasm, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.initialize(
    instance as unknown as {
      exports: { memory: WebAssembly.Memory; _initialize?: () => void };
    },
  );

  const engine = new TqlEngine(instance.exports as unknown as WasmExports);

  const actual = engine.grammarNames();
  const mismatch = grammars.find((g, i) => actual[i] !== g.key);
  if (mismatch !== undefined || actual.length !== grammars.length) {
    throw new Error(
      `grammar table is out of sync with the engine: expected [${grammars
        .map((g) => g.key)
        .join(", ")}], got [${actual.join(", ")}]`,
    );
  }

  return engine;
}
