import { type Fd, WASI } from "@bjorn3/browser_wasi_shim";

export interface GrammarInfo {
  key: string;
  displayName: string;
}

export const grammars: readonly GrammarInfo[] = [
  { key: "bash", displayName: "Bash" },
  { key: "cpp", displayName: "C++" },
  { key: "c", displayName: "C" },
  { key: "c_sharp", displayName: "C#" },
  { key: "css", displayName: "CSS" },
  { key: "dockerfile", displayName: "Dockerfile" },
  { key: "elixir", displayName: "Elixir" },
  { key: "erlang", displayName: "Erlang" },
  { key: "go", displayName: "Go" },
  { key: "graphql", displayName: "GraphQL" },
  { key: "haskell", displayName: "Haskell" },
  { key: "hcl", displayName: "HCL" },
  { key: "html", displayName: "HTML" },
  { key: "java", displayName: "Java" },
  { key: "javascript", displayName: "JavaScript" },
  { key: "json", displayName: "JSON" },
  { key: "kotlin", displayName: "Kotlin" },
  { key: "lua", displayName: "Lua" },
  { key: "make", displayName: "Make" },
  { key: "markdown", displayName: "Markdown" },
  { key: "nix", displayName: "Nix" },
  { key: "ocaml", displayName: "OCaml" },
  { key: "php", displayName: "PHP" },
  { key: "python", displayName: "Python" },
  { key: "ruby", displayName: "Ruby" },
  { key: "rust", displayName: "Rust" },
  { key: "scala", displayName: "Scala" },
  { key: "solidity", displayName: "Solidity" },
  { key: "toml", displayName: "TOML" },
  { key: "typescript", displayName: "TypeScript" },
  { key: "tsx", displayName: "TSX" },
  { key: "vue", displayName: "Vue" },
  { key: "yaml", displayName: "YAML" },
  { key: "zig", displayName: "Zig" },
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
  loadGrammar(name: string): Promise<Grammar>;
  parseTree(grammar: Grammar, target: string): TreeRow[];
}

export interface Grammar {
  readonly name: string;
  readonly ptr: number;
}

type CompileOptions =
  | { via: "streaming"; source: Response | PromiseLike<Response> }
  | { via: "buffer"; buffer: BufferSource };

export type Options = {
  compilation: CompileOptions;
  grammarSource?: (name: string) => CompileOptions;
};

interface WasmExports {
  memory: WebAssembly.Memory;
  tql_alloc(len: number): number;
  tql_free(ptr: number, len: number): void;
  tql_run_dynamic(
    languagePtr: number,
    queryPtr: number,
    queryLen: number,
    targetPtr: number,
    targetLen: number,
    outPtr: number,
  ): void;
  tql_parse_tree(
    languagePtr: number,
    targetPtr: number,
    targetLen: number,
    outPtr: number,
  ): void;
}

export interface TreeRow {
  depth: number;
  fieldName: string | null;
  type: string;
  isNamed: boolean;
  isMissing: boolean;
  startIndex: number;
  endIndex: number;
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
}

const RESULT_SIZE = 12;

async function toBytes(options: CompileOptions): Promise<Uint8Array> {
  switch (options.via) {
    case "streaming": {
      const response = await options.source;
      return new Uint8Array(await response.arrayBuffer());
    }
    case "buffer":
      return options.buffer instanceof Uint8Array
        ? options.buffer
        : new Uint8Array(
            ArrayBuffer.isView(options.buffer)
              ? options.buffer.buffer
              : options.buffer,
          );
  }
}

async function compile(options: CompileOptions): Promise<WebAssembly.Module> {
  switch (options.via) {
    case "streaming":
      return WebAssembly.compileStreaming(options.source);
    case "buffer":
      return WebAssembly.compile(options.buffer);
  }
}

function readTableMinimum(bytes: Uint8Array): number {
  let i = 8;
  const uleb = () => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = bytes[i++] ?? 0;
      result |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    return result >>> 0;
  };
  const skipName = () => {
    const len = uleb();
    i += len;
  };
  while (i < bytes.length) {
    const id = bytes[i++];
    const size = uleb();
    const end = i + size;
    const IMPORT_SECTION = 2;
    if (id !== IMPORT_SECTION) {
      i = end;
      continue;
    }
    const count = uleb();
    for (let n = 0; n < count; n++) {
      skipName();
      skipName();
      const kind = bytes[i++];
      const TABLE_KIND = 1;
      if (kind === TABLE_KIND) {
        i++;
        const limits = bytes[i++] ?? 0;
        const minimum = uleb();
        if (limits & 1) uleb();
        return minimum;
      }
      if (kind === 0) uleb();
      else if (kind === 2) {
        const limits = bytes[i++] ?? 0;
        uleb();
        if (limits & 1) uleb();
      } else i += 2;
    }
    return 0;
  }
  return 0;
}

function parseDylink(section: ArrayBuffer): {
  memorySize: number;
  memoryAlign: number;
  tableSize: number;
  tableAlign: number;
} {
  const b = new Uint8Array(section);
  let i = 0;
  const uleb = () => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      byte = b[i++] ?? 0;
      result |= (byte & 0x7f) << shift;
      shift += 7;
    } while (byte & 0x80);
    return result >>> 0;
  };
  const WASM_DYLINK_MEM_INFO = 1;
  const id = b[i++];
  uleb();
  if (id !== WASM_DYLINK_MEM_INFO) {
    throw new Error(`unexpected dylink subsection ${id}`);
  }
  return {
    memorySize: uleb(),
    memoryAlign: uleb(),
    tableSize: uleb(),
    tableAlign: uleb(),
  };
}

class TqlEngine implements Engine {
  private readonly encoder = new TextEncoder();
  private readonly decoder = new TextDecoder();
  private readonly loaded = new Map<string, Grammar>();
  private readonly pending = new Map<string, Promise<Grammar>>();

  constructor(
    private readonly exp: WasmExports,
    private readonly table: WebAssembly.Table,
    private readonly grammarSource?: (name: string) => CompileOptions,
  ) {}

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
      exp.tql_run_dynamic(
        args.grammar.ptr,
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
        throw new Error("tql_run_dynamic failed");
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

  async loadGrammar(name: string): Promise<Grammar> {
    const cached = this.loaded.get(name);
    if (cached) return cached;
    const pending = this.pending.get(name);
    if (pending) return pending;

    if (!this.grammarSource) {
      throw new Error("init() was called without a grammarSource");
    }
    const p = this.instantiateGrammar(name).then(g => {
      this.loaded.set(name, g);
      this.pending.delete(name);
      return g;
    });
    this.pending.set(name, p);
    return p;
  }

  parseTree(grammar: Grammar, target: string): TreeRow[] {
    const { exp } = this;
    const t = this.writeStr(target);
    const outPtr = exp.tql_alloc(RESULT_SIZE);
    if (outPtr === 0) {
      exp.tql_free(t.ptr, t.len);
      throw new Error("tql_alloc failed");
    }
    try {
      exp.tql_parse_tree(grammar.ptr, t.ptr, t.len, outPtr);
      return JSON.parse(this.readResult(outPtr)) as TreeRow[];
    } finally {
      exp.tql_free(t.ptr, t.len);
      exp.tql_free(outPtr, RESULT_SIZE);
    }
  }

  private async instantiateGrammar(name: string): Promise<Grammar> {
    const grammarSource = this.grammarSource;
    if (!grammarSource) {
      throw new Error("init() was called without a grammarSource");
    }
    const mod = await compile(grammarSource(name));
    const dylink = WebAssembly.Module.customSections(mod, "dylink.0")[0];
    if (dylink === undefined) {
      throw new Error(`grammar ${name}: not a wasm side module`);
    }
    const { memorySize, memoryAlign, tableSize } = parseDylink(dylink);

    const align = Math.max(1 << memoryAlign, 8);
    const raw = this.exp.tql_alloc(memorySize + align);
    if (raw === 0) throw new Error(`grammar ${name}: tql_alloc failed`);
    const memoryBase = (raw + align - 1) & ~(align - 1);

    const tableBase = this.table.length;
    if (tableSize > 0) this.table.grow(tableSize);

    const global = (v: number, mutable = false) =>
      new WebAssembly.Global({ value: "i32", mutable }, v);
    const instance = await WebAssembly.instantiate(mod, {
      env: {
        memory: this.exp.memory,
        __indirect_function_table: this.table,
        __memory_base: global(memoryBase),
        __table_base: global(tableBase),
        __stack_pointer: global(memoryBase + memorySize, true),
        __main_argc_argv: () => 0,
      },
      "GOT.mem": new Proxy({}, { get: () => global(0, true) }),
      "GOT.func": new Proxy({}, { get: () => global(0, true) }),
      wasi_snapshot_preview1: new Proxy({}, { get: () => () => 0 }),
    });

    const exports = instance.exports as Record<string, unknown>;
    (exports.__wasm_apply_data_relocs as (() => void) | undefined)?.();

    const key = Object.keys(exports).find(
      k => /^tree_sitter_\w+$/.test(k) && !k.includes("external_scanner"),
    );
    if (!key) throw new Error(`grammar ${name}: no tree_sitter_* export`);
    const ptr = (exports[key] as () => number)();
    if (!ptr) throw new Error(`grammar ${name}: null language pointer`);
    return { name, ptr };
  }

  private readResult(outPtr: number): string {
    const { exp } = this;
    const view = new DataView(exp.memory.buffer, outPtr, RESULT_SIZE);
    const status = view.getInt32(0, true);
    const dataPtr = view.getUint32(4, true);
    const dataLen = view.getUint32(8, true);
    if (dataLen === 0 && status !== 0) throw new Error("engine call failed");
    const bytes = new Uint8Array(exp.memory.buffer, dataPtr, dataLen).slice();
    exp.tql_free(dataPtr, dataLen);
    const text = this.decoder.decode(bytes);
    if (status !== 0) throw new Error(text);
    return text;
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
  const engineBytes = await toBytes(options.compilation);
  const wasm = await WebAssembly.compile(engineBytes);

  const table = new WebAssembly.Table({
    element: "anyfunc",
    initial: readTableMinimum(engineBytes),
  });

  const instance = await WebAssembly.instantiate(wasm, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: { __indirect_function_table: table },
  });
  wasi.initialize(
    instance as unknown as {
      exports: { memory: WebAssembly.Memory; _initialize?: () => void };
    },
  );

  const engine = new TqlEngine(
    instance.exports as unknown as WasmExports,
    table,
    options.grammarSource,
  );

  return engine;
}
