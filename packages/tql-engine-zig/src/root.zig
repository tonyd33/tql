//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
// IMPROVE: don't export this
pub const ts = @import("tree-sitter");
pub const runtime = @import("runtime.zig");
const pcre2 = @import("pcre2.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const language = @import("language.zig");
const query = @import("query.zig");
const engine = @import("engine.zig");

// IMPROVE: don't export this
pub const ds = @import("ds.zig");
pub const AST = ast;
pub const Parser = parser.Parser;
pub const Query = query.Query;
pub const Value = query.Value;
pub const Compiler = compiler.Compiler;
pub const Runtime = runtime;
pub const Language = language.Language;
pub const Engine = engine.Engine;
pub const CompiledQuery = engine.CompiledQuery;
pub const RunResult = engine.RunResult;
pub const RunStats = engine.RunStats;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@This());
    refAllDecls(runtime);
    refAllDecls(pcre2);
    refAllDecls(ast);
    refAllDecls(parser);
    refAllDecls(compiler);
    refAllDecls(language);
    refAllDecls(query);
    refAllDecls(engine);
    refAllDecls(@import("tests.zig"));
}
