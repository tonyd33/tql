#include "dyn_array.h"
#include "engine.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_typescript(void);

static const char *CONTROLLER_TEXT = "Controller";

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

int main() {
  const TSFieldId DECORATOR_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "decorator", 9);
  const TSFieldId FUNCTION_FIELD_ID =
      ts_language_field_id_for_name(tree_sitter_typescript(), "function", 8);
  const TSFieldId RETURN_TYPE_FIELD_ID = ts_language_field_id_for_name(
      tree_sitter_typescript(), "return_type", 11);
  const TSSymbol CLASS_DECLARATION_TYPE_SYMBOL = ts_language_symbol_for_name(
      tree_sitter_typescript(), "class_declaration", 17, true);

  const VarId DECORATOR_NAME_VAR_ID = 1;

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
                                 .data = {.texteq = {.node_expression =
                                                         NODE_EXPRESSION_SELF,
                                                     .text = CONTROLLER_TEXT}},
                             },
                     },
             });
  Ops_append(&prog_main, (Op){
                             .opcode = OP_BIND,
                             .data = {.var_id = DECORATOR_NAME_VAR_ID},
                         });
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

  // Build a syntax tree based on source code stored in a string.
  const char *source_code = "@NotController()\n"
                            "class UserService {}\n"
                            "@Controller()\n"
                            "class Other {}\n"
                            "const x = UserService();";
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
  char buf[1024];

  while (engine_next_match(&engine, &match)) {
    get_ts_node_text(source_code, match.node, buf);
    printf("match text:\n%s\n", buf);

    TQLValue *bound_value =
        bindings_get(&match.bindings, DECORATOR_NAME_VAR_ID);
    if (bound_value != NULL) {
      get_ts_node_text(source_code, *bound_value, buf);
      printf("bound text:\n%s\n", buf);
    }
    printf("=================\n");
  }

  // Free all of the heap-allocated memory.
  engine_free(&engine);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}
