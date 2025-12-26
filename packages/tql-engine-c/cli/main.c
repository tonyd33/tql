#include "dyn_array.h"
#include "engine.h"
#include "parser.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tql(void);

static const NodeExpression NODE_EXPRESSION_SELF = {
    .node_expression_type = NODEEXPR_SELF,
};

void get_ts_node_text(const char *source_code, TSNode node, char *buf) {
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  uint32_t buf_len = end_byte - start_byte;

  strncpy(buf, source_code + start_byte, buf_len);
  buf[buf_len] = '\0';
}

int run_demo(char *filename) {
  FILE *source_fp = fopen(filename, "rb");
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

  Ops prog_has_return_type;
  Ops_init(&prog_has_return_type);
  Ops_append(&prog_has_return_type,
             (Op){.opcode = OP_BRANCH,
                  .data = {.axis = {
                               .axis_type = AXIS_FIELD,
                               .data = {.field = RETURN_TYPE_FIELD_ID},
                           }}});
  Ops_append(&prog_has_return_type, (Op){
                                        .opcode = OP_YIELD,
                                    });
  Ops_append(&prog_has_return_type, (Op){
                                        .opcode = OP_RETURN,
                                    });
  Function function_has_return_type = {
      .id = 1,
      .function = prog_has_return_type,
  };

  Ops prog_main;
  Ops_init(&prog_main);
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BRANCH,
                             .data = {.axis =
                                          {
                                              .axis_type = AXIS_DESCENDANT,
                                          }},
                         });
  Ops_append(
      &prog_main,
      (Op){
          .opcode = OP_IF,
          .data = {.predicate =
                       {
                           .predicate_type = PREDICATE_TYPEEQ,
                           .negate = false,
                           .data =
                               {
                                   {.node_expression = NODE_EXPRESSION_SELF,
                                    .symbol = CLASS_DECLARATION_TYPE_SYMBOL},
                               },
                       }},
      });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_PUSHNODE,
                         });
  Ops_append(&prog_main,
             (Op){.opcode = OP_BRANCH,
                  .data = {.axis = {
                               .axis_type = AXIS_FIELD,
                               .data = {.field = DECORATOR_FIELD_ID},

                           }}});
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BRANCH,
                             .data = {.axis =
                                          {
                                              .axis_type = AXIS_CHILD,
                                          }},
                         });
  Ops_append(&prog_main,
             (Op){
                 .opcode = OP_BRANCH,
                 .data = {.axis =
                              {
                                  .axis_type = AXIS_FIELD,
                                  .data = {.field = FUNCTION_FIELD_ID},
                              }},
             });
  Ops_append(&prog_main,
             (Op){
                 .opcode = OP_IF,
                 .data =
                     {
                         .predicate =
                             {
                                 .predicate_type = PREDICATE_TEXTEQ,
                                 .negate = false,
                                 .data = {.texteq = {.node_expression =
                                                         NODE_EXPRESSION_SELF,
                                                     .text = "Controller"}},
                             },
                     },
             });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_POPNODE,
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_PUSHNODE,
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BRANCH,
                             .data = {.axis =
                                          {
                                              .axis_type = AXIS_FIELD,
                                              .data = {.field = NAME_FIELD_ID},
                                          }},
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BIND,
                             .data = {.var_id = CLASS_NAME_VAR_ID},
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_POPNODE,
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_PUSHNODE,
                         });
  Ops_append(&prog_main, (Op){.opcode = OP_BRANCH,
                              .data = {.axis = {
                                           .axis_type = AXIS_FIELD,
                                           .data = {.field = BODY_FIELD_ID},
                                       }}});
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BRANCH,
                             .data = {.axis =
                                          {
                                              .axis_type = AXIS_CHILD,
                                          }},
                         });
  Ops_append(
      &prog_main,
      (Op){
          .opcode = OP_IF,
          .data = {.predicate =
                       {
                           .predicate_type = PREDICATE_TYPEEQ,
                           .negate = false,
                           .data =
                               {
                                   {.node_expression = NODE_EXPRESSION_SELF,
                                    .symbol = METHOD_DEFINITION_TYPE_SYMBOL},
                               },
                       }},
      });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_PUSHNODE,
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BRANCH,
                             .data = {.axis =
                                          {
                                              .axis_type = AXIS_FIELD,
                                              .data = {.field = NAME_FIELD_ID},
                                          }},
                         });
  Ops_append(&prog_main,
             (Op){
                 .opcode = OP_IF,
                 .data =
                     {
                         .predicate =
                             {
                                 .predicate_type = PREDICATE_TEXTEQ,
                                 .negate = true,
                                 .data = {.texteq = {.node_expression =
                                                         NODE_EXPRESSION_SELF,
                                                     .text = "constructor"}},
                             },
                     },
             });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BIND,
                             .data = {.var_id = METHOD_NAME_VAR_ID},
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_POPNODE,
                         });
  Ops_append(&prog_main, (Op){.opcode = OP_CALL,
                              .data = {.call_parameters = {
                                           .mode = CALLMODE_NOTEXISTS,
                                           .function_id = 1,
                                       }}});
  Ops_append(&prog_main, (Op){
                             .opcode = OP_POPNODE,
                         });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_YIELD,
                         });
  Function function_main = {
      .id = 0,
      .function = prog_main,
  };

  // Create a parser.
  TSParser *parser = ts_parser_new();

  ts_parser_set_language(parser, tree_sitter_typescript());

  TSTree *tree =
      ts_parser_parse_string(parser, NULL, source_code, strlen(source_code));

  Engine engine;
  engine_init(&engine);
  engine_load_source(&engine, source_code);
  engine_load_ast(&engine, tree);
  engine_load_function(&engine, &function_has_return_type);
  engine_load_function(&engine, &function_main);
  engine_exec(&engine);

  Match match;
  TQLValue *bound_value;
  TSPoint start_point;
  TSPoint end_point;
  char buf[4096];

  while (engine_next_match(&engine, &match)) {
    printf("=================\n");
    bound_value = bindings_get(&match.bindings, CLASS_NAME_VAR_ID);
    if (bound_value != NULL) {
      get_ts_node_text(source_code, *bound_value, buf);
      start_point = ts_node_start_point(*bound_value);
      end_point = ts_node_end_point(*bound_value);
      printf("class name: %s (row %u, column %u – row %u, column %u)\n", buf,
             start_point.row, start_point.column, end_point.row,
             end_point.column);
    }

    bound_value = bindings_get(&match.bindings, METHOD_NAME_VAR_ID);
    if (bound_value != NULL) {
      get_ts_node_text(source_code, *bound_value, buf);
      start_point = ts_node_start_point(*bound_value);
      end_point = ts_node_end_point(*bound_value);
      printf("method name: %s (row %u, column %u – row %u, column %u)\n", buf,
             start_point.row, start_point.column, end_point.row,
             end_point.column);
    }

    get_ts_node_text(source_code, match.node, buf);
    start_point = ts_node_start_point(match.node);
    end_point = ts_node_end_point(match.node);
    printf("full match: (row %u, column %u – row %u, column %u)\n%s\n",
           start_point.row, start_point.column, end_point.row, end_point.column,
           buf);
    printf("=================\n");
  }

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

  return parse_tql(argv[1]);
  /* return run_demo(argv[1]); */
}
