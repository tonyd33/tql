#include "dyn_array.h"
#include "engine.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_typescript(void);

int main() {
  printf("starting\n");
  Ops program;
  Ops_init(&program);
  Ops_append(&program, (Op){
                           .opcode = Push,
                           .operand = NULL,
                       });
  Ops_append(&program, (Op){
                           .opcode = Bind,
                           .operand = (void *)1,
                       });
  Ops_append(&program, (Op){
                           .opcode = Pop,
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
  const char *source_code = "console.log('hello world')";
  TSTree *tree =
      ts_parser_parse_string(parser, NULL, source_code, strlen(source_code));

  Engine engine;
  engine_init(&engine);
  engine_load_ast(&engine, tree);
  engine_load_program(&engine, &program);

  printf("Running...\n");
  Matches *matches = engine_run(&engine);
  printf("Matches: %zu\n", matches->len);

  for (int i = 0; i < matches->len; i++) {
    Match match = matches->data[i];
    printf("symbol: %d\n", ts_node_symbol(match.node));
  }

  // Free all of the heap-allocated memory.
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}
