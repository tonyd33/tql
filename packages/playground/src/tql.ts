import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from "@bjorn3/browser_wasi_shim";

const LANG = { c: 0, typescript: 1, tsx: 2 };

// TODO: make small js wrapper
export async function start() {
  const args = ["bin", "arg1", "arg2"];
  const env = ["FOO=bar"];
  const fds = [
      new OpenFile(new File([])), // stdin
      ConsoleStdout.lineBuffered(msg => console.log(`[WASI stdout] ${msg}`)),
      ConsoleStdout.lineBuffered(msg => console.warn(`[WASI stderr] ${msg}`)),
      new PreopenDirectory(".", [
          ["example.c", new File(new TextEncoder("utf-8").encode(`#include "a"`))],
          ["hello.rs", new File(new TextEncoder("utf-8").encode(`fn main() { println!("Hello World!"); }`))],
      ]),
  ];
  const wasi = new WASI(args, env, fds);

  const wasm = await WebAssembly.compileStreaming(fetch("./tql.wasm"));
  const instance = await WebAssembly.instantiate(wasm, {
      "wasi_snapshot_preview1": wasi.wasiImport,
  });
  wasi.initialize(instance);

  const exp = instance.exports;
  const mem = exp.memory;

  const writeStr = (s) => {
    const buf = new TextEncoder().encode(s);
    const ptr = exp.tql_alloc(buf.length);
    new Uint8Array(mem.buffer, ptr, buf.length).set(buf);
    return { ptr, len: buf.length };
  };
  const readStr = (ptrFn, lenFn) =>
    new TextDecoder().decode(new Uint8Array(mem.buffer, ptrFn(), lenFn()));

  const query = 'select function_definition.declarator';
  const source = `
int add(int a, int b) { return a + b; }
int main(void) { return add(1, 2); }
`;

  const q = writeStr(query);
  const t = writeStr(source);

  const rc = exp.tql_run(LANG.c, q.ptr, q.len, t.ptr, t.len);
  if (rc !== 0) {
    console.error('tql_run failed:', readStr(exp.tql_last_error_ptr, exp.tql_last_error_len));
    process.exit(1);
  }

  const result = JSON.parse(readStr(exp.tql_last_result_ptr, exp.tql_last_result_len));
  console.log(result);

  exp.tql_free(q.ptr, q.len);
  exp.tql_free(t.ptr, t.len);
}
