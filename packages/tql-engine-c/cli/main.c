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

static inline SymbolEntry *find_se(Engine *engine, Symbol symbol) {
  for (size_t i = 0; i < engine->symtab.len; i++) {
    SymbolEntry *se = &engine->symtab.data[i];
    if (se->id == symbol) {
      return se;
    }
  }
  return NULL;
}

void print_bindings(Engine *engine, const char *source_code,
                    Bindings *bindings) {
  char buf[8192];
  while (bindings != NULL) {
    TSNode node = bindings->binding.value;
    SymbolEntry *se = find_se(engine, bindings->binding.variable);
    get_ts_node_text(source_code, node, buf);
    printf("%s: %s\n", se != NULL ? se->slice.buf : "unknown",
           strlen(buf) > 20 ? "(too long)" : buf);
    bindings = bindings->parent;
  }
}

int run(const char *query_filename, const char *source_filename) {
  char *tql_buf = NULL;
  uint32_t tql_length = 0;
  char *source_code = NULL;
  uint32_t source_length = 0;

  {
    FILE *fp = fopen(query_filename, "r");
    if (fp == NULL) {
      perror("fopen");
      return EXIT_FAILURE;
    }
    fseek(fp, 0, SEEK_END);
    tql_length = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    tql_buf = malloc(tql_length);
    assert(fread(tql_buf, 1, tql_length, fp) == tql_length);
    fclose(fp);
  }
  {
    FILE *fp = fopen(source_filename, "r");
    if (fp == NULL) {
      perror("fopen");
      return EXIT_FAILURE;
    }
    fseek(fp, 0, SEEK_END);
    source_length = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    source_code = malloc(source_length);
    assert(fread(source_code, 1, source_length, fp) == source_length);
    fclose(fp);
  }
  Engine *engine = engine_new();
  engine_compile_query(engine, tql_buf, tql_length);
  engine_load_target_string(engine, source_code, source_length);
  engine_exec(engine);

  Match match;
  char buf[4096];

  while (engine_next_match(engine, &match)) {
    assert(!ts_node_is_null(match.node));
    print_bindings(engine, source_code, match.bindings);
    get_ts_node_text(source_code, match.node, buf);
    printf("Full match: \n%s\n", buf);
    printf("\n");
  }
  EngineStats stats = engine_stats(engine);
  printf("================================ Engine Stats "
         "==================================\n");
  printf("SI  String count: %u\n", stats.string_count);
  printf("SI  String allocation: %u\n", stats.string_alloc);
  printf("AST Arena allocation: %u\n", stats.ast_stats.arena_alloc);
  printf("VM  Boundaries encountered: %u\n",
         stats.vm_stats.boundaries_encountered);
  printf("VM  Total branching: %u\n", stats.vm_stats.total_branching);
  printf("VM  Max branching factor: %u\n", stats.vm_stats.max_branching_factor);
  printf("VM  Max stack size: %u\n", stats.vm_stats.max_stack_size);
  printf("VM  Step count: %u\n", stats.vm_stats.step_count);
  printf("====================================================================="
         "===========\n");

  engine_free(engine);
  free(source_code);
  free(tql_buf);

  return EXIT_SUCCESS;
}
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Expected 1 argument\n");
    return EXIT_FAILURE;
  }

  return run(argv[1], argv[2]);
}
