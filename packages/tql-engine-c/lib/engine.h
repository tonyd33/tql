#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "ast.h"
#include "compiler.h"
#include "ds.h"
#include "vm.h"

#include <tree_sitter/api.h>

typedef struct EngineStats {
  VmStats vm_stats;
  TQLAstStats ast_stats;
  uint32_t string_count;
  uint32_t string_alloc;
} EngineStats;

typedef struct Engine {
  TQLAst *ast;
  Vm *vm;
  StringInterner *string_interner;
  Program program;
  StringSlice target_source;
  TSTree *target_ast;
  SymbolTable symtab;
  EngineStats stats;
} Engine;

Engine *engine_new(void);
void engine_free(Engine *engine);

void engine_compile_query(Engine *engine, const char *buf, uint32_t length);
void engine_load_target_string(Engine *engine, const char *buf,
                               uint32_t length);
void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

EngineStats engine_stats(Engine *engine);

#endif /* _ENGINE_H_ */
