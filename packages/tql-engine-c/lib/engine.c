#include "engine.h"
#include "ast.h"
#include "compiler.h"
#include "parser.h"

struct Engine {
  TQLAst *ast;
  Vm *vm;
  StringInterner *string_interner;
  Program program;
  StringSlice target_source;
  TSTree *target_ast;
};

Engine *engine_new() {
  Engine *engine = malloc(sizeof(Engine));
  engine->ast = NULL;
  engine->vm = NULL;
  engine->target_ast = NULL;

  engine->string_interner = string_interner_new(32768);
  return engine;
}

void engine_free(Engine *engine) {
  string_interner_free(engine->string_interner);
  engine->string_interner = NULL;

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

  if (engine->program.data != NULL) {
    free(engine->program.data);
  }
}

void engine_compile_query(Engine *engine, const char *buf, uint32_t length) {
  TQLParser *parser = tql_parser_new(engine->string_interner);
  engine->ast = tql_parser_parse_string(parser, buf, length);
  tql_parser_free(parser);

  TQLCompiler *compiler = tql_compiler_new(engine->ast);
  engine->program = tql_compiler_compile(compiler);
  tql_compiler_free(compiler);
}

void engine_load_target_string(Engine *engine, const char *buf,
                               uint32_t length) {
  StringSlice target;
  char *dest = malloc(length);
  strncpy(dest, buf, length);

  target.buf = dest;
  target.length = length;

  engine->target_source = target;
  TSParser *target_parser = ts_parser_new();
  ts_parser_set_language(target_parser, engine->program.target_language);
  engine->target_ast =
      ts_parser_parse_string(target_parser, NULL, engine->target_source.buf,
                             engine->target_source.length);
  ts_parser_delete(target_parser);
}

void engine_exec(Engine *engine) {
  assert(engine->target_ast != NULL);
  assert(engine->target_source.buf != NULL);
  assert(engine->program.data != NULL);
  engine->vm = vm_new(engine->target_ast, engine->target_source.buf);
  vm_load(engine->vm, engine->program);
  vm_exec(engine->vm);
}

bool engine_next_match(Engine *engine, Match *match) {
  assert(engine->vm != NULL);
  return vm_next_match(engine->vm, match);
}

const VmStats *engine_get_vm_stats(const Engine *engine) {
  assert(engine->vm != NULL);
  return vm_stats(engine->vm);
}
