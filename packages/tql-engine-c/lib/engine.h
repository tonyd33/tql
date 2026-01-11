#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "ast.h"
#include "compiler.h"
#include "ds.h"
#include "vm.h"

#include <tree_sitter/api.h>

typedef struct {
  VmStats vm_stats;
  uint32_t arena_alloc;
  uint32_t string_count;
  uint32_t string_alloc;
} TQLEngineStats;

typedef struct {
  TQLContext *ctx;
  TQLAst *ast;
  Vm *vm;
  TQLProgram *program;
  StringSlice target_source;
  TSTree *target_ast;
  SymbolTable symtab;
  TQLEngineStats stats;
} TQLEngine;

typedef struct {
  char *name;
  TQLValue *value;
} TQLCapture;

typedef struct EngineMatch {
  TSNode node;
  TQLCapture *captures;
  uint32_t capture_count;
} EngineMatch;

TQLEngine *tql_engine_new(void);
void tql_engine_free(TQLEngine *engine);

void tql_engine_compile_query(TQLEngine *engine, const char *buf, uint32_t length);
void tql_engine_load_target_string(TQLEngine *engine, const char *buf,
                               uint32_t length);
void tql_engine_exec(TQLEngine *engine);
bool tql_engine_next_match(TQLEngine *engine, EngineMatch *match);

TQLEngineStats tql_engine_stats(TQLEngine *engine);

#endif /* _ENGINE_H_ */
