#include "engine.h"
#include "parser.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tql(void);

void get_ts_node_text(const char *source_code, TSNode node, char *buf) {
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  uint32_t buf_len = end_byte - start_byte;

  strncpy(buf, source_code + start_byte, buf_len);
  buf[buf_len] = '\0';
}

int run_demo(char *filename) {
  FILE *source_fp = fopen(filename, "r");
  if (source_fp == NULL) {
    perror("fopen");
    return EXIT_FAILURE;
  }
  char source_code[4096] = {0};
  int bytes_read = fread(source_code, sizeof(source_code), 1, source_fp);
  printf("Read %d bytes\n", bytes_read);

  const TSFieldId DECORATOR_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "decorator", 9);
  const TSFieldId FUNCTION_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "function", 8);
  const TSFieldId BODY_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "body", 4);
  const TSFieldId NAME_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "name", 4);
  const TSFieldId RETURN_TYPE_FIELD_ID = ts_language_field_id_for_name(
      tree_sitter_typescript(), "return_type", 11);
  const TSSymbol CLASS_DECLARATION_TYPE_SYMBOL = ts_language_symbol_for_name(
      tree_sitter_typescript(), "class_declaration", 17, true);
  const TSSymbol METHOD_DEFINITION_TYPE_SYMBOL = ts_language_symbol_for_name(
      tree_sitter_typescript(), "method_definition", 17, true);

  const VarId CLASS_NAME_VAR_ID = 1;
  const VarId METHOD_NAME_VAR_ID = 2;

  Op ops[] = {
      /* main */
      op_branch(axis_child()),
      op_if(predicate_typeeq(node_expression_self(),
                             CLASS_DECLARATION_TYPE_SYMBOL)),
      /* find controller decorator */
      op_pushnode(),
      op_branch(axis_field(DECORATOR_FIELD_ID)),
      op_branch(axis_child()),
      op_branch(axis_field(FUNCTION_FIELD_ID)),
      op_if(predicate_texteq(node_expression_self(), "Controller")),
      op_popnode(),

      /* find method without return type and bind */
      op_pushnode(),
      op_branch(axis_field(BODY_FIELD_ID)),
      op_branch(axis_child()),
      op_if(predicate_typeeq(node_expression_self(),
                             METHOD_DEFINITION_TYPE_SYMBOL)),
      op_probe(probe_not_exists(jump_relative(9))),
      op_branch(axis_field(NAME_FIELD_ID)),
      op_bind(METHOD_NAME_VAR_ID),
      op_popnode(),
      op_yield(),
      op_halt(),

      /* bind class name */
      op_pushnode(),
      op_branch(axis_field(NAME_FIELD_ID)),
      op_bind(CLASS_NAME_VAR_ID),
      op_popnode(),

      /* has return type */
      op_branch(axis_field(RETURN_TYPE_FIELD_ID)),
      op_yield(),
      op_halt(),
  };

  // Create a parser.
  TSParser *parser = ts_parser_new();

  ts_parser_set_language(parser, tree_sitter_typescript());

  TSTree *tree =
      ts_parser_parse_string(parser, NULL, source_code, strlen(source_code));

  Engine engine;
  engine_init(&engine, tree, source_code);
  engine_load_program(&engine, ops, sizeof(ops) / sizeof(ops[0]));
  engine_exec(&engine);

  Match match;
  TQLValue *bound_value;
  TSPoint start_point;
  TSPoint end_point;
  char buf[4096];

  while (engine_next_match(&engine, &match)) {
    bound_value = bindings_get(match.bindings, CLASS_NAME_VAR_ID);
    if (bound_value != NULL) {
      get_ts_node_text(source_code, *bound_value, buf);
      printf("class name: %s \n", buf);
    }

    bound_value = bindings_get(match.bindings, METHOD_NAME_VAR_ID);
    if (bound_value != NULL) {
      get_ts_node_text(source_code, *bound_value, buf);
      printf("method name: %s \n", buf);
    }

    // assert(!ts_node_is_null(match.node));
    // get_ts_node_text(source_code, match.node, buf);
    // start_point = ts_node_start_point(match.node);
    // end_point = ts_node_end_point(match.node);
    // printf("full match: \n%s\n", buf);
    printf("\n");
  }
  printf("Arena allocation: %zu\n", engine.arena->offset);
  printf("Boundaries encountered: %u\n", engine.stats.boundaries_encountered);
  printf("Total branching: %u\n", engine.stats.total_branching);
  printf("Max branching factor: %u\n", engine.stats.max_branching_factor);
  printf("Max stack size: %u\n", engine.stats.max_stack_size);
  printf("Step count: %u\n", engine.stats.step_count);

  fclose(source_fp);
  // Free all of the heap-allocated memory.
  engine_free(&engine);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return EXIT_SUCCESS;
}

int parse_tql(char *filename) {
  FILE *fp = fopen(filename, "rb");
  char buf[8192] = {0};
  int bytes_read = fread(buf, sizeof(buf), 1, fp);
  printf("Read %d bytes\n", bytes_read);

  TQLParser parser;
  tql_parser_init(&parser);

  TQLAst *ast = tql_parser_parse_string(&parser, buf, strlen(buf));
  printf("stored %u strings\n", ast->string_pool->string_count);
  // FIXME: This is wrong
  printf("used %u bytes for strings\n",
         ast->string_pool->offsets[ast->string_pool->string_count - 1]);
  printf("used %zu bytes for ast\n", ast->arena->offset);
  tql_ast_free(ast);
  tql_parser_free(&parser);
  fclose(fp);
  return EXIT_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "Expected 1 argument\n");
    return EXIT_FAILURE;
  }

  // return parse_tql(argv[1]);
  return run_demo(argv[1]);
}
