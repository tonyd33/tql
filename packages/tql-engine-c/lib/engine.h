#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "ds.h"
#include "program.h"
#include <tree_sitter/api.h>

typedef TSNode TQLValue;

struct Bindings;
struct NodeStack;
struct PCStack;
struct Match;
struct NodeStack;
struct DelimitedExecution;
struct LookaheadBoundary;
struct EngineStats;
struct Engine;

typedef struct Bindings Bindings;
typedef struct NodeStack NodeStack;
typedef struct PCStack PCStack;
typedef struct DelimitedExecution DelimitedExecution;
typedef struct LookaheadBoundary LookaheadBoundary;
typedef struct EngineStats EngineStats;
typedef struct Engine Engine;

struct Match {
  TSNode node;
  Bindings *bindings;
};

typedef struct {
  uint32_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack *node_stk;
  PCStack *pc_stk;
} Continuation;

struct DelimitedExecution {
  Continuation *cnt_stk;
  Continuation *sp;
};

struct LookaheadBoundary {
  ProbeMode call_mode;
  DelimitedExecution del_exc;
  Continuation continuation;
};

struct EngineStats {
  uint32_t step_count;
  uint32_t boundaries_encountered;
  uint32_t total_branching;
  uint32_t max_branching_factor;
  uint32_t max_stack_size;
};

struct Engine {
  TSTree *ast;
  const char *source;

  Op *ops;
  uint32_t op_count;
  Arena *arena;
  uint32_t stk_cap;

  DelimitedExecution del_exc;

  EngineStats stats;
};

TQLValue *bindings_get(Bindings *bindings, VarId variable);

void engine_init(Engine *engine, TSTree *ast, const char *source);
void engine_load_program(Engine *engine, Op *ops, uint32_t op_count);

void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

void engine_free(Engine *engine);

#endif /* _ENGINE_H_ */
