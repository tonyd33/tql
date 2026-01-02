#include "util.h"
#include "lib/compiler.h"
#include "lib/ds.h"
#include "lib/ast.h"
#include "lib/parser.h"
#include <string.h>

const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_typescript(void);

bool test_compiler_detect_language() {
  const char *source = "#language 'c' fn main() { translation_unit }";
  StringInterner *interner = string_interner_new(16384);
  TQLParser *parser = tql_parser_new(interner);
  TQLAst *ast = tql_parser_parse_string(parser, source, strlen(source));
  TQLCompiler *compiler = tql_compiler_new(ast);

  Program prog = tql_compiler_compile(compiler);
  expect(prog.target_language == tree_sitter_c());

  tql_compiler_free(compiler);
  string_interner_free(interner);
  tql_ast_free(ast);

  return true;
}

bool test_compiler() {
  expect(test_compiler_detect_language());
  return true;
}
