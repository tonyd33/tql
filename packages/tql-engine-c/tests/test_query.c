#include "lib/ds.h"
#include "lib/engine.h"
#include "util.h"
#include <string.h>

static void concat_binds(String *s, const String source_file,
                         EngineMatch *match) {
  for (uint32_t i = 0; i < match->capture_count; i++) {
    TQLCapture capture = match->captures[i];
    String capture_text;
    switch (capture.value->type) {
    case TQL_VALUE_NODE:
      capture_text = get_ts_node_text(source_file, capture.value->data.node);
      break;
    case TQL_VALUE_SYMBOL:
      string_init(&capture_text);
      string_extend(s, string_from("a string (not implemented)"));
      break;
    }
    string_extend(s, string_from(capture.name));
    string_extend(s, string_from(": "));
    string_extend(s, capture_text);
    string_append(s, '\n');
    string_deinit(&capture_text);
  }
}

static bool test_query_suite(const char *suite) {
  char filename[1024] = {0};
  sprintf(filename, "./tests/queries/%s/query.tql", suite);
  String query_file = read_file(filename);
  sprintf(filename, "./tests/queries/%s/source.ts", suite);
  String source_file = read_file(filename);
  sprintf(filename, "./tests/queries/%s/snapshot.txt", suite);
  String snapshot = read_file(filename);

  TQLEngine *engine = tql_engine_new();
  tql_engine_compile_query(engine, query_file.data, query_file.len);
  tql_engine_load_target_string(engine, source_file.data, source_file.len);
  tql_engine_exec(engine);

  EngineMatch match;
  String actual;
  string_init(&actual);
  while (tql_engine_next_match(engine, &match)) {
    expect(!ts_node_is_null(match.node));
    String match_text = get_ts_node_text(source_file, match.node);
    string_extend(&actual,
                  string_from("==================================== MATCH "
                              "=====================================\n"));
    string_extend(&actual, string_from("NODE\n\n"));
    string_extend(&actual, match_text);
    string_extend(&actual, string_from("\n\n"));
    string_extend(&actual, string_from("BINDINGS\n\n"));
    concat_binds(&actual, source_file, &match);
    string_append(&actual, '\n');
    string_extend(&actual,
                  string_from("==========================================="
                              "=====================================\n"));
    string_deinit(&match_text);
  }

  // printf("%.*s\n", (int)actual.len, actual.data);
  expect(snapshot.len == actual.len);
  expect(strncmp(snapshot.data, actual.data, snapshot.len) == 0);
  string_deinit(&actual);

  tql_engine_free(engine);
  string_deinit(&snapshot);
  string_deinit(&source_file);
  string_deinit(&query_file);
  return true;
}

bool test_query() {
  expect(test_query_suite("function"));
  expect(test_query_suite("no-duplicate"));
  expect(test_query_suite("or"));
  expect(test_query_suite("decorator"));
  return true;
}
