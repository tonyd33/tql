#include "lib/ast.h"
#include "lib/compiler.h"
#include "lib/parser.h"
#include "lib/vm.h"
#include "util.h"
#include <string.h>

const TSLanguage *tree_sitter_tql(void);

static bool test_compiler_detect_language() {
  const char *source = "#language 'tql' fn main() { translation_unit }";
  TQLContext *ctx = tql_context_new();
  TQLParser *parser = tql_parser_new(ctx);
  TQLAst *ast = tql_parser_parse_string(parser, source, strlen(source));
  TQLCompiler *compiler = tql_compiler_new(ast);

  Program *prog = tql_compiler_compile(compiler);
  expect(prog->target_language == tree_sitter_tql());

  program_free(prog);
  tql_ast_free(ast);
  tql_compiler_free(compiler);
  tql_parser_free(parser);
  tql_context_free(ctx);

  return true;
}

static bool test_compile_function() {
  const char *source = "#language 'c'"
                       "fn main() {"
                       "@foo <- 'hi';"
                       "translation_unit;"
                       "@baz <- translation_unit;"
                       "}";
  TQLContext *ctx = tql_context_new();
  TQLParser *parser = tql_parser_new(ctx);
  TQLAst *ast = tql_parser_parse_string(parser, source, strlen(source));
  TQLCompiler *compiler = tql_compiler_new(ast);

  Program *prog = tql_compiler_compile(compiler);
  expect(prog->target_language == tree_sitter_tql());

  program_free(prog);
  tql_ast_free(ast);
  tql_compiler_free(compiler);
  tql_parser_free(parser);
  tql_context_free(ctx);

  return true;
}

bool test_compiler() {
  expect(test_compiler_detect_language());
  // expect(test_compile_function());
  return true;
}
