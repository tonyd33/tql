import { WASI } from "@bjorn3/browser_wasi_shim";
export var Language;
(function (Language) {
    Language[Language["c"] = 0] = "c";
    Language[Language["typescript"] = 1] = "typescript";
    Language[Language["tsx"] = 2] = "tsx";
})(Language || (Language = {}));
const RESULT_SIZE = 12;
async function compile(options) {
    switch (options.via) {
        case "streaming":
            return WebAssembly.compileStreaming(options.source);
        case "buffer":
            return WebAssembly.compile(options.buffer);
    }
}
class TqlEngine {
    exp;
    encoder = new TextEncoder();
    decoder = new TextDecoder();
    constructor(exp) {
        this.exp = exp;
    }
    query(args) {
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
            if (status !== 0)
                throw new Error(text);
            return JSON.parse(text);
        }
        finally {
            exp.tql_free(query.ptr, query.len);
            exp.tql_free(target.ptr, target.len);
            exp.tql_free(outPtr, RESULT_SIZE);
        }
    }
    writeStr(s) {
        const buf = this.encoder.encode(s);
        const ptr = this.exp.tql_alloc(buf.length);
        if (ptr === 0 && buf.length !== 0)
            throw new Error("tql_alloc failed");
        new Uint8Array(this.exp.memory.buffer, ptr, buf.length).set(buf);
        return { ptr, len: buf.length };
    }
}
export async function init(options) {
    const args = [];
    const env = [];
    const fds = [];
    const wasi = new WASI(args, env, fds);
    const wasm = await compile(options.compilation);
    const instance = await WebAssembly.instantiate(wasm, {
        wasi_snapshot_preview1: wasi.wasiImport,
    });
    wasi.initialize(instance);
    return new TqlEngine(instance.exports);
}
//# sourceMappingURL=index.js.map