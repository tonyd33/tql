export declare enum Language {
    cpp = 0,
    c = 1,
    go = 2,
    javascript = 3,
    python = 4,
    rust = 5,
    tsx = 6,
    typescript = 7,
    zig = 8
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
type CompileOptions = {
    via: "streaming";
    source: Response | PromiseLike<Response>;
} | {
    via: "buffer";
    buffer: BufferSource;
};
export type Options = {
    compilation: CompileOptions;
};
export declare function init(options: Options): Promise<Engine>;
export {};
//# sourceMappingURL=index.d.ts.map