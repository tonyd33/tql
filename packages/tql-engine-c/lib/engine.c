#include "engine.h"
#include "ast.h"
#include "compiler.h"
#include "parser.h"

struct Engine {
  TQLParser *parser;
  TQLAst *ast;
  Compiler *compiler;
  Vm *vm;
};

Engine *engine_new() {
  Engine *engine = malloc(sizeof(Engine));
  engine->parser = NULL;
  engine->ast = NULL;
  engine->compiler = NULL;
  engine->vm = NULL;
  return engine;
}

void engine_load(Engine *engine, const char *buf, uint32_t length) {
  engine->parser = tql_parser_new();
  engine->ast = tql_parser_parse_string(engine->parser, buf, length);
}

void engine_free(Engine *engine) {
  if (engine->ast != NULL) {
    tql_ast_free(engine->ast);
    engine->parser = NULL;
  }
  if (engine->parser != NULL) {
    tql_parser_free(engine->parser);
    engine->parser = NULL;
  }
  if (engine->compiler != NULL) {
    compiler_free(engine->compiler);
    engine->compiler = NULL;
  }
  if (engine->vm != NULL) {
    vm_free(engine->vm);
    engine->vm = NULL;
  }
}
