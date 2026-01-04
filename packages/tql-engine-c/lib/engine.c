#include "engine.h"
#include "ast.h"
#include "compiler.h"
#include "parser.h"

Engine *engine_new(void) {
  Engine *engine = malloc(sizeof(Engine));
  engine->ast = NULL;
  engine->vm = NULL;
  engine->target_ast = NULL;
  engine->target_source.buf = NULL;
  engine->target_source.length = 0;

  engine->ctx = tql_context_new();
  symbol_table_init(&engine->symtab);
  return engine;
}

void engine_free(Engine *engine) {
  symbol_table_deinit(&engine->symtab);
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
    program_free(engine->program);
  }
  if (engine->target_source.buf != NULL) {
    char *buf = *((char **)(&engine->target_source.buf));
    free(buf);
    engine->target_source.buf = NULL;
    engine->target_source.length = 0;
  }

  free(engine);
}

void engine_compile_query(Engine *engine, const char *buf, uint32_t length) {
  TQLParser *parser = tql_parser_new(engine->ctx);
  engine->ast = tql_parser_parse_string(parser, buf, length);
  tql_parser_free(parser);

  TQLCompiler *compiler = tql_compiler_new(engine->ast);
  engine->program = tql_compiler_compile(compiler);
  tql_compiler_free(compiler);
}

void engine_load_target_string(Engine *engine, const char *buf,
                               uint32_t length) {
  assert(engine->program != NULL);

  StringSlice target;
  char *dest = malloc(length);
  strncpy(dest, buf, length);

  target.buf = dest;
  target.length = length;

  engine->target_source = target;
  TSParser *target_parser = ts_parser_new();
  ts_parser_set_language(target_parser, engine->program->target_language);
  engine->target_ast =
      ts_parser_parse_string(target_parser, NULL, engine->target_source.buf,
                             engine->target_source.length);
  ts_parser_delete(target_parser);
}

void engine_exec(Engine *engine) {
  assert(engine->target_ast != NULL);
  assert(engine->target_source.buf != NULL);
  assert(engine->program != NULL);
  engine->vm = vm_new(engine->target_ast, engine->target_source.buf);
  vm_load(engine->vm, engine->program);
  vm_exec(engine->vm);
}

bool engine_next_match(Engine *engine, Match *match) {
  assert(engine->vm != NULL);
  return vm_next_match(engine->vm, match);
}

EngineStats engine_stats(Engine *engine) {
  assert(engine->vm != NULL);
  uint32_t string_interner_usage = 0;
  for (size_t i = 0; i < engine->ctx->string_interner->slices.len; i++) {
    string_interner_usage +=
        engine->ctx->string_interner->slices.data[i].length;
  }
  engine->stats.string_count = engine->ctx->string_interner->slices.len;
  engine->stats.string_alloc = string_interner_usage;
  engine->stats.vm_stats = vm_stats(engine->vm);
  return engine->stats;
}
