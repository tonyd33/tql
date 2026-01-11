#define PCRE2_CODE_UNIT_WIDTH 8
#include "engine.h"
#include "vm.h"
#include <assert.h>
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <tree_sitter/api.h>

static inline String *read_file(const char *filename) {
  String *s = string_new();
  FILE *fp = fopen(filename, "r");
  if (fp == NULL) {
    perror("fopen");
    assert(false);
  }

  fseek(fp, 0, SEEK_END);
  uint32_t length = ftell(fp);
  fseek(fp, 0, SEEK_SET);

  string_reserve(s, length);
  s->len = length;
  assert(fread(s->data, 1, length, fp) == length);
  fclose(fp);
  return s;
}

static inline String get_ts_node_text(const String source, TSNode node) {
  String s;
  string_init(&s);
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  uint32_t buf_len = end_byte - start_byte;

  string_reserve(&s, buf_len);
  s.len = buf_len;
  strncpy(s.data, source.data + start_byte, buf_len);
  return s;
}

int run(const char *query_filename, const char *source_filename) {
  String *query = read_file(query_filename);
  String *source = read_file(source_filename);

  TQLEngine *engine = tql_engine_new();
  tql_engine_compile_query(engine, query->data, query->len);
  tql_engine_load_target_string(engine, source->data, source->len);
  tql_engine_exec(engine);

  EngineMatch match;

  while (tql_engine_next_match(engine, &match)) {
    assert(!ts_node_is_null(match.node));
    String text = get_ts_node_text(*source, match.node);
    printf("==================================== MATCH "
           "=====================================\n");
    printf("NODE\n\n");
    printf("%.*s\n\n", (int)text.len, text.data);
    string_deinit(&text);

    printf("BINDINGS\n\n");
    for (uint32_t i = 0; i < match.capture_count; i++) {
      TQLCapture capture = match.captures[i];
      printf("%s: ", capture.name);
      String capture_text;
      switch (capture.value->type) {
      case TQL_VALUE_NODE:
        capture_text = get_ts_node_text(*source, capture.value->data.node);
        break;
      case TQL_VALUE_SYMBOL: {
        String s = string_from("a string (not implemented)");
        string_init(&capture_text);
        string_extend(&capture_text, string_from("a string (not implemented)"));
      } break;
      }
      printf("%.*s\n", (int)capture_text.len, capture_text.data);
      string_deinit(&capture_text);
    }
    printf("\n");
    printf("==========================================="
           "=====================================\n");
  }
  TQLEngineStats stats = tql_engine_stats(engine);
  printf("================================ Engine Stats "
         "==================================\n");
  printf("AR Arena allocation: %u\n", stats.arena_alloc);
  printf("SI String count: %u\n", stats.string_count);
  printf("SI String allocation: %u\n", stats.string_alloc);
  printf("VM Boundaries encountered: %u\n",
         stats.vm_stats.boundaries_encountered);
  printf("VM Total branching: %u\n", stats.vm_stats.total_branching);
  printf("VM Max branching factor: %u\n", stats.vm_stats.max_branching_factor);
  printf("VM Max stack size: %u\n", stats.vm_stats.max_stack_size);
  printf("VM Step count: %u\n", stats.vm_stats.step_count);
  printf("====================================================================="
         "===========\n");

  tql_engine_free(engine);
  string_free(query);
  string_free(source);

  return EXIT_SUCCESS;
}
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Expected 1 argument\n");
    return EXIT_FAILURE;
  }

  return run(argv[1], argv[2]);
}
