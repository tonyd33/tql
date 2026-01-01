#include "compiler.h"
#include "parser.h"
#include "vm.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

void get_ts_node_text(const char *source_code, TSNode node, char *buf) {
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  uint32_t buf_len = end_byte - start_byte;

  strncpy(buf, source_code + start_byte, buf_len);
  buf[buf_len] = '\0';
}

int run(const char *query_filename, const char *source_filename) {
  char tql_buf[4096] = {0};
  char source_code[4096] = {0};

  {
    FILE *fp = fopen(query_filename, "rb");
    if (fp == NULL) {
      perror("fopen");
      return EXIT_FAILURE;
    }
    fread(tql_buf, 1, sizeof(tql_buf), fp);
    fclose(fp);
  }
  {
    FILE *fp = fopen(source_filename, "r");
    if (fp == NULL) {
      perror("fopen");
      return EXIT_FAILURE;
    }
    fread(source_code, 1, sizeof(source_code), fp);
    fclose(fp);
  }

  TQLParser *parser = tql_parser_new();
  TQLAst *ast = tql_parser_parse_string(parser, tql_buf, strlen(tql_buf));
  {
    printf("=== Parser Stats ===\n");
    printf("Stored %zu strings\n", ast->string_interner->slices.len);
    printf("Used %zu bytes for ast\n", ast->arena->offset);
    printf("====================\n");
  }
  tql_parser_free(parser);

  Compiler *compiler = compiler_new(ast);
  Program program = tql_compiler_compile(compiler);
  // FIXME: It's a mistake that strings used in the engine are stored in this
  // ast. We should be able to free the ast at this step!

  TSParser *target_parser = ts_parser_new();
  ts_parser_set_language(target_parser, tql_compiler_target(compiler));
  TSTree *tree = ts_parser_parse_string(target_parser, NULL, source_code,
                                        strlen(source_code));
  ts_parser_delete(target_parser);

  Vm *vm = vm_new(tree, source_code);
  vm_load(vm, program);
  vm_exec(vm);

  Match match;
  char buf[4096];

  while (vm_next_match(vm, &match)) {
    assert(!ts_node_is_null(match.node));
    get_ts_node_text(source_code, match.node, buf);
    printf("Full match: \n%s\n", buf);
    printf("\n");
  }
  const VmStats *stats = vm_stats(vm);
  printf("=== Engine Stats ===\n");
  // printf("Arena allocation: %zu\n", engine->arena->offset);
  printf("Boundaries encountered: %u\n", stats->boundaries_encountered);
  printf("Total branching: %u\n", stats->total_branching);
  printf("Max branching factor: %u\n", stats->max_branching_factor);
  printf("Max stack size: %u\n", stats->max_stack_size);
  printf("Step count: %u\n", stats->step_count);
  printf("====================\n");

  tql_ast_free(ast);
  vm_free(vm);

  return EXIT_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Expected 1 argument\n");
    return EXIT_FAILURE;
  }

  return run(argv[1], argv[2]);
}
