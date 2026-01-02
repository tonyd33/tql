#include "engine.h"
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
  Engine *engine = engine_new();
  engine_compile_query(engine, tql_buf, strlen(tql_buf));
  engine_load_target_string(engine, source_code, strlen(source_code));
  engine_exec(engine);

  Match match;
  char buf[4096];

  while (engine_next_match(engine, &match)) {
    assert(!ts_node_is_null(match.node));
    get_ts_node_text(source_code, match.node, buf);
    printf("Full match: \n%s\n", buf);
    printf("\n");
  }
  const VmStats *stats = engine_get_vm_stats(engine);
  printf("=== VM Stats ===\n");
  // printf("Arena allocation: %zu\n", engine->arena->offset);
  printf("Boundaries encountered: %u\n", stats->boundaries_encountered);
  printf("Total branching: %u\n", stats->total_branching);
  printf("Max branching factor: %u\n", stats->max_branching_factor);
  printf("Max stack size: %u\n", stats->max_stack_size);
  printf("Step count: %u\n", stats->step_count);
  printf("================\n");

  engine_free(engine);

  return EXIT_SUCCESS;
}
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Expected 1 argument\n");
    return EXIT_FAILURE;
  }

  return run(argv[1], argv[2]);
}
