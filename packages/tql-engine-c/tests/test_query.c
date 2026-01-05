#include "lib/ds.h"
#include "lib/engine.h"
#include "util.h"
#include <string.h>

static void concat_binds(String *s, const String source_file,
                         EngineMatch *match) {
  for (uint32_t i = 0; i < match->capture_count; i++) {
    TQLCapture capture = match->captures[i];
    String capture_text = get_ts_node_text(source_file, capture.node);
    string_concat(s, string_from(capture.name));
    string_concat(s, string_from(": "));
    string_concat(s, capture_text);
    string_append(s, '\n');
    string_deinit(&capture_text);
  }
}

static bool test_query_decorator() {
  String query_file = read_file("./tests/queries/decorator/query.tql");
  String source_file = read_file("./tests/queries/decorator/source.ts");
  String snapshot = read_file("./tests/queries/decorator/snapshot.txt");

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
    string_concat(&actual,
                  string_from("==================================== MATCH "
                              "=====================================\n"));
    string_concat(&actual, string_from("NODE\n\n"));
    string_concat(&actual, match_text);
    string_concat(&actual, string_from("\n\n"));
    string_concat(&actual, string_from("BINDINGS\n\n"));
    concat_binds(&actual, source_file, &match);
    string_append(&actual, '\n');
    string_concat(&actual,
                  string_from("==========================================="
                              "=====================================\n"));
    string_deinit(&match_text);
  }

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
  expect(test_query_decorator());
  return true;
}
