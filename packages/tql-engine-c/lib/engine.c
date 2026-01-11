#include "engine.h"
#include "ast.h"
#include "compiler.h"
#include "parser.h"

TQLEngine *tql_engine_new(void) {
  TQLEngine *engine = malloc(sizeof(TQLEngine));
  engine->ast = NULL;
  engine->vm = NULL;
  engine->target_ast = NULL;
  engine->target_source.data = NULL;
  engine->target_source.len = 0;

  engine->ctx = tql_context_new();
  return engine;
}

void tql_engine_free(TQLEngine *engine) {
  tql_context_free(engine->ctx);
  engine->ctx = NULL;

  if (engine->ast != NULL) {
    tql_ast_free(engine->ast);
    engine->ast = NULL;
  }
  if (engine->vm != NULL) {
    vm_free(engine->vm);
    engine->vm = NULL;
  }
  if (engine->target_ast != NULL) {
    ts_tree_delete(engine->target_ast);
    engine->target_ast = NULL;
  }
  if (engine->program != NULL) {
    tql_program_free(engine->program);
  }
  if (engine->target_source.data != NULL) {
    char *buf = *((char **)(&engine->target_source.data));
    free(buf);
    engine->target_source.data = NULL;
    engine->target_source.len = 0;
  }

  free(engine);
}

void tql_engine_compile_query(TQLEngine *engine, const char *buf,
                              uint32_t length) {
  TQLParser *parser = tql_parser_new(engine->ctx);
  engine->ast = tql_parser_parse_string(parser, buf, length);
  tql_parser_free(parser);

  TQLCompiler *compiler = tql_compiler_new(engine->ctx, engine->ast);
  engine->program = tql_compiler_compile(compiler);
  tql_compiler_free(compiler);
}

void tql_engine_load_target_string(TQLEngine *engine, const char *buf,
                                   uint32_t length) {
  assert(engine->program != NULL);

  StringSlice target;
  char *dest = malloc(length);
  strncpy(dest, buf, length);

  target.data = dest;
  target.len = length;

  engine->target_source = target;
  TSParser *target_parser = ts_parser_new();
  ts_parser_set_language(target_parser, engine->program->target_language);
  engine->target_ast =
      ts_parser_parse_string(target_parser, NULL, engine->target_source.data,
                             engine->target_source.len);
  ts_parser_delete(target_parser);
}

void tql_engine_exec(TQLEngine *engine) {
  assert(engine->target_ast != NULL);
  assert(engine->target_source.data != NULL);
  assert(engine->program != NULL);
  engine->vm = vm_new(engine->target_ast, engine->target_source.data);
  vm_load(engine->vm, engine->program);
  vm_exec(engine->vm);
}

char *lookup_symbol_name(const SymbolTable *symtab, Symbol symbol) {
  String s;
  string_init(&s);
  for (size_t i = 0; i < symtab->len; i++) {
    SymbolEntry entry = symtab->data[i];
    if (entry.type == SYMBOL_VARIABLE && entry.id == symbol) {
      // FIXME
      return (char *)entry.slice.data;
    }
  }
  assert(false);
}

bool tql_engine_next_match(TQLEngine *engine, EngineMatch *engine_match) {
  assert(engine->vm != NULL);
  Match match;
  if (vm_next_match(engine->vm, &match)) {
    uint32_t bindings_count = 0;
    Bindings *bindings = match.bindings;
    while (bindings != NULL) {
      bindings_count++;
      bindings = bindings->parent;
    }
    // FIXME: This is so stupid
    TQLCapture *captures =
        tql_context_alloc(engine->ctx, sizeof(TQLCapture) * bindings_count);

    bindings_count = 0;
    bindings = match.bindings;
    while (bindings != NULL) {
      captures[bindings_count++] =
          (TQLCapture){.name = lookup_symbol_name(engine->program->symtab,
                                                  bindings->binding.variable),
                       .value = &bindings->binding.value};
      bindings = bindings->parent;
    }
    engine_match->node = match.node;
    engine_match->captures = captures;
    engine_match->capture_count = bindings_count;
    return true;
  } else {
    return false;
  }
}

TQLEngineStats tql_engine_stats(TQLEngine *engine) {
  assert(engine->vm != NULL);
  uint32_t string_interner_usage = 0;
  for (size_t i = 0; i < engine->ctx->string_interner->slices.len; i++) {
    string_interner_usage +=
        engine->ctx->string_interner->slices.data[i].len;
  }
  engine->stats.arena_alloc = engine->ctx->arena->offset;
  engine->stats.string_count = engine->ctx->string_interner->slices.len;
  engine->stats.string_alloc = string_interner_usage;
  engine->stats.vm_stats = vm_stats(engine->vm);
  return engine->stats;
}
