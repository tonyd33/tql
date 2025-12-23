#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "binding.h"
#include "dyn_array.h"
#include <tree_sitter/api.h>

DA_DEFINE(TSNode, TSNodes);

typedef struct {
  TSNode node;
  Bindings *bindings;
} Match;

typedef enum {
  Noop,
  PushNode,
  PopNode,
  Branch,
  Bind,
  If,
  Yield,
} Opcode;

typedef struct {
  Opcode opcode;
  void *operand;
} Op;

typedef enum {
  Child,
  Descendant,
  Field,
} AxisType;

typedef struct {
  AxisType axis_type;
  void *operand;
} Axis;

DA_DEFINE(Op, Ops);
DA_DEFINE(Match, Matches);
DA_DEFINE(TSNode, NodeStack);

typedef struct {
  uint64_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack *node_stack;
} Frame;
DA_DEFINE(Frame, Stack);

typedef struct {
  TSTree *ast;
  Ops program;
} Engine;

void engine_init(Engine *engine);
void engine_free(Engine *engine);

/*
 * In this step, I imagine the engine to take note of the source language and
 * AST and determine what optimizations it can make.
 */
void engine_load_ast(Engine *engine, TSTree *ast);
void engine_load_program(Engine *engine, Ops *program);

Matches *engine_run(Engine *engine);

#endif /* _ENGINE_H_ */
