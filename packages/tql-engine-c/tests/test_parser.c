#include "lib/ds.h"
#include "lib/parser.h"
#include "util.h"

static bool test_parse_include() {
  const char *src1 = "#language 'c'";
  const char *src2 = "#language 'phony'";
  TQLAst *ast;
  StringInterner *interner = string_interner_new(16384);
  TQLParser *parser = tql_parser_new(interner);

  ast = tql_parser_parse_string(parser, src1, strlen(src1));
  expect(ast->tree->directive_count == 1);
  expect(ast->tree->directives[0]->type == TQLDIRECTIVE_TARGET);
  expect(string_slice_eq(*ast->tree->directives[0]->data.import,
                         string_slice_from("c")));
  tql_ast_free(ast);

  ast = tql_parser_parse_string(parser, src2, strlen(src2));
  expect(ast->tree->directive_count == 1);
  expect(ast->tree->directives[0]->type == TQLDIRECTIVE_TARGET);
  expect(string_slice_eq(*ast->tree->directives[0]->data.import,
                         string_slice_from("phony")));
  tql_ast_free(ast);

  tql_parser_free(parser);
  string_interner_free(interner);
  return true;
}

static bool test_parse_function() {
  const char *src1 = "fn my_function(@foo, @bar) { a > b; @baz <- c > d; @qux <- 'Hi'; }";
  TQLAst *ast;
  StringInterner *interner = string_interner_new(16384);
  TQLParser *parser = tql_parser_new(interner);

  ast = tql_parser_parse_string(parser, src1, strlen(src1));
  expect(ast->tree->function_count == 1);
  expect(string_slice_eq(*ast->tree->functions[0]->identifier,
                         string_slice_from("my_function")));
  expect(ast->tree->functions[0]->parameter_count == 2);
  expect(string_slice_eq(*ast->tree->functions[0]->parameters[0],
                         string_slice_from("@foo")));
  expect(string_slice_eq(*ast->tree->functions[0]->parameters[1],
                         string_slice_from("@bar")));
  expect(ast->tree->functions[0]->statement_count == 3);
  expect(ast->tree->functions[0]->statements[0]->type == TQLSTATEMENT_SELECTOR);
  expect(ast->tree->functions[0]->statements[0]->data.selector->type ==
         TQLSELECTOR_CHILD);
  expect(ast->tree->functions[0]
             ->statements[0]
             ->data.selector->data.child_selector.parent->type ==
         TQLSELECTOR_NODETYPE);
  expect(string_slice_eq(
      *ast->tree->functions[0]
           ->statements[0]
           ->data.selector->data.child_selector.parent->data.node_type_selector,
      string_slice_from("a")));
  expect(ast->tree->functions[0]
             ->statements[0]
             ->data.selector->data.child_selector.child->type ==
         TQLSELECTOR_NODETYPE);
  expect(string_slice_eq(
      *ast->tree->functions[0]
           ->statements[0]
           ->data.selector->data.child_selector.child->data.node_type_selector,
      string_slice_from("b")));

  expect(ast->tree->functions[0]->statements[1]->type ==
         TQLSTATEMENT_ASSIGNMENT);
  expect(string_slice_eq(*ast->tree->functions[0]
                              ->statements[1]
                              ->data.assignment->variable_identifier,
                         string_slice_from("@baz")));
  expect(ast->tree->functions[0]
             ->statements[1]
             ->data.assignment->expression->type == TQLEXPRESSION_SELECTOR);

  expect(ast->tree->functions[0]->statements[2]->type ==
         TQLSTATEMENT_ASSIGNMENT);
  expect(string_slice_eq(*ast->tree->functions[0]
                              ->statements[2]
                              ->data.assignment->variable_identifier,
                         string_slice_from("@qux")));
  expect(ast->tree->functions[0]
             ->statements[2]
             ->data.assignment->expression->type == TQLEXPRESSION_STRING);

  tql_ast_free(ast);

  tql_parser_free(parser);
  string_interner_free(interner);
  return true;
}

bool test_parser() {
  expect(test_parse_include());
  expect(test_parse_function());
  return true;
}
