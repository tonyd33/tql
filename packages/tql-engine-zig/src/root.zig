//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const ts = @import("tree-sitter");
const runtime = @import("./runtime.zig");
const pcre2 = @import("./pcre2.zig");
const ast = @import("./ast.zig");
const parser = @import("./parser.zig");
const compiler = @import("./compiler.zig");
const engine = @import("./engine.zig");

pub const Engine = engine.Engine;
pub const Language = engine.Language;
pub const CompiledQuery = engine.CompiledQuery;
pub const QueryResult = engine.QueryResult;
pub const CompileStats = engine.CompileStats;
pub const Match = engine.Match;
pub const Node = engine.Node;
pub const Value = engine.Value;

pub const AST = ast;

pub const Parser = parser.Parser;

pub const Compiler = compiler.Compiler;
pub const Program = compiler.Program;

pub const Runtime = runtime;

test {
    const refAllDecls = std.testing.refAllDecls;
    refAllDecls(@This());
    refAllDecls(runtime);
    refAllDecls(pcre2);
    refAllDecls(ast);
    refAllDecls(parser);
    refAllDecls(compiler);
    refAllDecls(engine);
}
