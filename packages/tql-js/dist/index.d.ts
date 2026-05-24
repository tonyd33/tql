export declare enum Language {
    c = 0,
    typescript = 1,
    tsx = 2
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