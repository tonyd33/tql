#include "util.h"
#include "lib/ds.h"
#include "lib/parser.h"
#include "lib/ds.h"

bool test_parse_include() {
  const char *src1 = "#language 'c'";
  const char *src2 = "#language 'phony'";
  TQLAst *ast;
  StringInterner *interner = string_interner_new(16384);
  TQLParser *parser = tql_parser_new(interner);

  ast = tql_parser_parse_string(parser, src1, strlen(src1));
  tql_ast_free(ast);

  ast = tql_parser_parse_string(parser, src2, strlen(src2));
  tql_ast_free(ast);

  tql_parser_free(parser);
  string_interner_free(interner);
  return true;
}

bool test_parser() {
  expect(test_parse_include());
  return true;
}
