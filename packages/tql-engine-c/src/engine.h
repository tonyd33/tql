#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "binding.h"
#include "dyn_array.h"
#include <tree_sitter/api.h>

typedef struct {
  TSNode node;
  Bindings *bindings;
} Match;

typedef enum {
  Noop,
  Push,
  Pop,
  Transition,
  Bind,
  Yield,
} Opcode;

typedef struct {
  Opcode opcode;
  void *operand;
} Op;

DA_DEFINE(Op, Ops);
DA_DEFINE(Match, Matches);
DA_DEFINE(TSNode, NodeStack);

typedef struct {
  uint64_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack node_stack;
} Frame;
DA_DEFINE(Frame, Stack);

typedef struct {
  TSTree *ast;
  Ops program;
  Stack stack;
} Engine;

void engine_init(Engine *engine);
void engine_free(Engine *engine);

void engine_load_ast(Engine *engine, TSTree *ast);
void engine_load_program(Engine *engine, Ops *program);

Matches *engine_run(Engine *engine);

#endif /* _ENGINE_H_ */
