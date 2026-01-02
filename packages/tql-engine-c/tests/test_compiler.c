#include "util.h"
#include "lib/compiler.h"
#include "lib/ds.h"
#include "lib/ast.h"
#include "lib/parser.h"
#include "lib/vm.h"
#include <string.h>

const TSLanguage *tree_sitter_tql(void);

bool test_compiler_detect_language() {
  const char *source = "#language 'tql' fn main() { translation_unit }";
  StringInterner *interner = string_interner_new(16384);
  SymbolTable *symtab = symbol_table_new();
  TQLParser *parser = tql_parser_new(interner);
  TQLAst *ast = tql_parser_parse_string(parser, source, strlen(source));
  TQLCompiler *compiler = tql_compiler_new(ast, symtab);

  Program prog = tql_compiler_compile(compiler);
  expect(prog.target_language == tree_sitter_tql());

  symbol_table_free(symtab);
  tql_compiler_free(compiler);
  string_interner_free(interner);
  tql_ast_free(ast);

  return true;
}

bool test_compiler() {
  expect(test_compiler_detect_language());
  return true;
}
