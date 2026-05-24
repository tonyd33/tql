import { WASI, type Fd } from "@bjorn3/browser_wasi_shim";

export enum Language {
  c = 0,
  typescript = 1,
  tsx = 2,
}

export interface QueryArgs {
  querySource: string;
  queryTarget: string;
  language: Language;
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
      exp.tql_run(args.language, query.ptr, query.len, target.ptr, target.len, outPtr);
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
  wasi.initialize(instance as unknown as { exports: { memory: WebAssembly.Memory; _initialize?: () => void } });

  return new TqlEngine(instance.exports as unknown as WasmExports);
}
