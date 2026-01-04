#include "lib/ds.h"
#include "lib/engine.h"
#include "lib/vm.h"
#include "util.h"
#include <stdio.h>
#include <string.h>

String lookup_symbol_name(const SymbolTable *symtab, Symbol symbol) {
  String s;
  string_init(&s);
  for (size_t i = 0; i < symtab->len; i++) {
    SymbolEntry entry = symtab->data[i];
    if (entry.type == SYMBOL_VARIABLE && entry.id == symbol) {
      string_reserve(&s, entry.slice.length);
      strncpy(s.data, entry.slice.buf, entry.slice.length);
      s.len = entry.slice.length;
      return s;
    }
  }
  assert(false);
}

static void concat_binds(String *s, const String source_file,
                         const Bindings *bindings, const SymbolTable *symtab) {
  while (bindings != NULL) {
    String binding_text =
        get_ts_node_text(source_file, bindings->binding.value);
    String name = lookup_symbol_name(symtab, bindings->binding.variable);
    string_concat(s, name);
    string_concat(s, string_from(": "));
    string_concat(s, binding_text);
    string_append(s, '\n');
    string_deinit(&name);
    string_deinit(&binding_text);
    bindings = bindings->parent;
  }
}

static bool test_query_decorator() {
  String query_file = read_file("./tests/queries/decorator/query.tql");
  String source_file = read_file("./tests/queries/decorator/source.ts");
  String snapshot = read_file("./tests/queries/decorator/snapshot.txt");

  Engine *engine = engine_new();
  engine_compile_query(engine, query_file.data, query_file.len);
  engine_load_target_string(engine, source_file.data, source_file.len);
  engine_exec(engine);

  uint32_t match_count = 0;
  Match match;
  String actual;
  string_init(&actual);
  while (engine_next_match(engine, &match)) {
    expect(!ts_node_is_null(match.node));
    String match_text = get_ts_node_text(source_file, match.node);
    string_concat(&actual,
                  string_from("==================================== MATCH "
                              "=====================================\n"));
    string_concat(&actual, string_from("NODE\n\n"));
    string_concat(&actual, match_text);
    string_concat(&actual, string_from("\n\n"));
    string_concat(&actual, string_from("BINDINGS\n\n"));
    concat_binds(&actual, source_file, match.bindings, engine->program->symtab);
    string_append(&actual, '\n');
    string_concat(&actual,
                  string_from("==========================================="
                              "=====================================\n"));
    string_deinit(&match_text);
  }

  expect(snapshot.len == actual.len);
  expect(strncmp(snapshot.data, actual.data, snapshot.len) == 0);
  string_deinit(&actual);

  engine_free(engine);
  string_deinit(&snapshot);
  string_deinit(&source_file);
  string_deinit(&query_file);
  return true;
}

bool test_query() {
  expect(test_query_decorator());
  return true;
}
