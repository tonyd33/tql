#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "binding.h"
#include "dyn_array.h"
#include <tree_sitter/api.h>

typedef uint64_t FunctionId;

DA_DEFINE(TSNode, TSNodes);

typedef struct {
  TSNode node;
  Bindings bindings;
} Match;

typedef enum {
  AXIS_CHILD,
  AXIS_DESCENDANT,
  AXIS_FIELD,
} AxisType;

typedef struct {
  AxisType axis_type;
  union {
    TSFieldId field;
  } data;
} Axis;

typedef enum {
  PREDICATE_TEXTEQ,
  PREDICATE_TYPEEQ,
} PredicateType;

typedef enum {
  NODEEXPR_SELF,
  NODEEXPR_VAR,
} NodeExpressionType;

typedef struct {
  NodeExpressionType node_expression_type;
  union {
    VarId var_id;
  } operand;
} NodeExpression;

typedef struct {
  PredicateType predicate_type;
  union {
    struct {
      NodeExpression node_expression;
      TSSymbol symbol;
    } typeeq;
    struct {
      NodeExpression node_expression;
      // TODO: Create a symbol lookup table and use a reference to the symbol
      // id here. This is currently dangerous, since the string is not owned by
      // the engine.
      const char *text;
    } texteq;
  } data;
} Predicate;

typedef enum {
  CALLMODE_JOIN,
  CALLMODE_EXISTS,
  CALLMODE_NOTEXISTS,
} CallMode;

typedef struct {
  CallMode mode;
  FunctionId function_id;
} CallParameters;

typedef enum {
  OP_NOOP,
  OP_PUSHNODE,
  OP_POPNODE,
  OP_BRANCH,
  OP_BIND,
  OP_IF,
  OP_CALL,
  OP_YIELD,
} Opcode;

typedef struct {
  Opcode opcode;
  union {
    Axis axis;
    Predicate predicate;
    VarId var_id;
  } data;
} Op;

DA_DEFINE(Op, Ops);
DA_DEFINE(Match, Matches);
DA_DEFINE(TSNode, NodeStack);

typedef Ops FunctionBody;

typedef struct {
  FunctionId id;
  FunctionBody function;
} Function;
DA_DEFINE(Function, FunctionTable);

typedef struct {
  uint64_t pc;
  TSNode node;
  Bindings bindings;
  NodeStack node_stack;
} ExecutionFrame;
DA_DEFINE(ExecutionFrame, ExecutionStack);

typedef struct {
  TSTree *ast;
  FunctionTable function_table;
  ExecutionStack stack;
  const char *source;
} Engine;

void engine_init(Engine *engine);

/*
 * In this step, I imagine the engine to take note of the source language and
 * AST and determine what optimizations it can make.
 */
void engine_load_ast(Engine *engine, TSTree *ast);
void engine_load_source(Engine *engine, const char *source);
void engine_load_function(Engine *engine, Function *function);

void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

void engine_free(Engine *engine);

#endif /* _ENGINE_H_ */
