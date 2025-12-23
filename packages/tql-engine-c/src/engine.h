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
  Child,
  Descendant,
  Field,
} AxisType;

typedef struct {
  AxisType axis_type;
  void *operand;
} Axis;

typedef enum {
  /* operand_1: NodeExpression, operand_2: String */
  TextEquals,
  /* operand_1: NodeExpression, operand_2: Id */
  TypeEquals,
} PredicateType;

typedef enum {
  Self,
  Var,
} NodeExpressionType;

typedef struct {
  NodeExpressionType node_expression_type;
  void *operand;
} NodeExpression;

typedef struct {
  PredicateType predicate_type;
  void *operand_1;
  void *operand_2;
} Predicate;

typedef enum {
  Join,
  Exists,
  NotExists,
} CallMode;

typedef struct {
  CallMode mode;
  uint64_t function_id;
} CallParameters;

typedef enum {
  Noop,
  PushNode,
  PopNode,
  Branch,
  Bind,
  If,
  Call,
  Yield,
} Opcode;

// TODO: We really need a typesafe way to encode operations!
// And this should ideally be completely flat in memory.
typedef struct {
  Opcode opcode;
  void *operand;
} Op;

DA_DEFINE(Op, Ops);
DA_DEFINE(Match, Matches);
DA_DEFINE(TSNode, NodeStack);

typedef Ops FunctionBody;

typedef struct {
  uint64_t id;
  FunctionBody function;
} Function;
DA_DEFINE(Function, FunctionTable);

typedef struct {
  uint64_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack *node_stack;
} Frame;
DA_DEFINE(Frame, Stack);

typedef struct {
  TSTree *ast;
  FunctionTable function_table;
  Stack stack;
  const char *source;
} Engine;

void engine_init(Engine *engine);

/*
 * In this step, I imagine the engine to take note of the source language and
 * AST and determine what optimizations it can make.
 */
void engine_load_ast(Engine *engine, TSTree *ast);
void engine_load_source(Engine *engine, const char* source);
void engine_load_function(Engine *engine, Function *function);

void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

void engine_free(Engine *engine);

#endif /* _ENGINE_H_ */
