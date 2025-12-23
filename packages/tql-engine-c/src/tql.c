#include "dyn_array.h"
#include "engine.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_typescript(void);

int main() {
  Ops program;
  Ops_init(&program);

  TSFieldId decorator_field_id =
      ts_language_field_id_for_name(tree_sitter_typescript(), "decorator", 9);
  TSFieldId function_field_id =
      ts_language_field_id_for_name(tree_sitter_typescript(), "function", 8);

  Axis descendant_axis = {
      .axis_type = Descendant,
      .operand = NULL,
  };
  Axis child_axis = {
      .axis_type = Child,
      .operand = NULL,
  };
  Axis decorator_field_axis = {
      .axis_type = Field,
      .operand = (void *)decorator_field_id,
  };
  Axis function_field_axis = {
      .axis_type = Field,
      .operand = (void *)function_field_id,
  };
  Ops_append(&program, (Op){
                           .opcode = PushNode,
                           .operand = NULL,
                       });
  Ops_append(&program, (Op){
                           .opcode = Branch,
                           .operand = &descendant_axis,
                       });
  Ops_append(&program, (Op){
                           .opcode = Branch,
                           .operand = &decorator_field_axis,
                       });
  Ops_append(&program, (Op){
                           .opcode = Branch,
                           .operand = &child_axis,
                       });
  Ops_append(&program, (Op){
                           .opcode = Branch,
                           .operand = &function_field_axis,
                       });
  Ops_append(&program, (Op){
                           .opcode = Bind,
                           .operand = (void *)1,
                       });
  Ops_append(&program, (Op){
                           .opcode = PopNode,
                           .operand = NULL,
                       });
  Ops_append(&program, (Op){
                           .opcode = Yield,
                           .operand = NULL,
                       });

  // Create a parser.
  TSParser *parser = ts_parser_new();

  ts_parser_set_language(parser, tree_sitter_typescript());

  // Build a syntax tree based on source code stored in a string.
  const char *source_code = "@Controller()\n"
                            "class UserService {}\n"
                            "@SomethingElse()\n"
                            "class Other {}";
  TSTree *tree =
      ts_parser_parse_string(parser, NULL, source_code, strlen(source_code));

  Engine engine;
  engine_init(&engine);
  engine_load_ast(&engine, tree);
  engine_load_program(&engine, &program);

  Matches *matches = engine_run(&engine);

  char buf[1024];
  for (int i = 0; i < matches->len; i++) {
    Match match = matches->data[i];
    uint32_t start_byte = ts_node_start_byte(match.node);
    uint32_t end_byte = ts_node_end_byte(match.node);
    uint32_t buf_len = end_byte - start_byte;
    strncpy(buf, source_code + start_byte, buf_len);
    buf[buf_len] = '\0';

    printf("match text: %s\n", buf);
    TQLValue *bound_value = bindings_get(match.bindings, 1);
    if (bound_value != NULL) {
      uint32_t start_byte = ts_node_start_byte(*bound_value);
      uint32_t end_byte = ts_node_end_byte(*bound_value);
      uint32_t buf_len = end_byte - start_byte;
      strncpy(buf, source_code + start_byte, buf_len);
      buf[buf_len] = '\0';

      printf("bound text: %s\n", buf);
    }
  }

  engine_free(&engine);
  // Free all of the heap-allocated memory.
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}
