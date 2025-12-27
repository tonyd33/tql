#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "binding.h"
#include "ds.h"
#include <tree_sitter/api.h>

typedef uint64_t FunctionId;

DA_DEFINE(TSNode, TSNodes)

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
  bool negate;
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
  CALLMODE_PASSTHROUGH,
  CALLMODE_EXISTS,
  CALLMODE_NOTEXISTS,
} CallMode;

typedef struct {
  CallMode mode;
  bool relative;
  int32_t pc;
} CallParameters;

typedef enum {
  OP_NOOP,
  OP_BRANCH,
  OP_BIND,
  OP_IF,
  OP_CALL,
  OP_RETURN,
  OP_YIELD,
  OP_PUSHNODE,
  OP_POPNODE,
} Opcode;

typedef struct {
  Opcode opcode;
  union {
    Axis axis;
    Predicate predicate;
    VarId var_id;
    CallParameters call_parameters;
  } data;
} Op;

DA_DEFINE(Op, Ops)
DA_DEFINE(Match, Matches)

struct NodeStack;
typedef struct NodeStack NodeStack;

typedef struct {
  uint64_t pc;
  TSNode node;
  Bindings bindings;
  NodeStack *node_stack;
} ExecutionFrame;
DA_DEFINE(ExecutionFrame, ExecutionStack)

typedef struct CallFrame CallFrame;

struct CallFrame {
  CallMode call_mode;
  ExecutionStack exc_stack;
  bool has_continuation;
  ExecutionFrame continuation;
};
DA_DEFINE(CallFrame, CallStack)

typedef struct {
  Arena *arena;
  TSTree *ast;
  CallStack call_stack;
  const char *source;
  uint32_t step_count;
  Ops ops;
} Engine;

void engine_init(Engine *engine);

/*
 * In this step, I imagine the engine to take note of the source language and
 * AST and determine what optimizations it can make.
 */
void engine_load_ast(Engine *engine, TSTree *ast);
void engine_load_source(Engine *engine, const char *source);
void engine_load_program(Engine *engine, Op *ops, uint32_t op_count);

void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

void engine_free(Engine *engine);

Axis axis_field(TSFieldId field_id);
Axis axis_child();
Axis axis_descendant();

Predicate predicate_typeeq(NodeExpression ne, TSSymbol symbol);
Predicate predicate_texteq(NodeExpression ne, const char *string);
Predicate predicate_negate(Predicate predicate);

NodeExpression node_expression_self();

Op op_noop();
Op op_branch(Axis axis);
Op op_bind(VarId var_id);
Op op_if(Predicate predicate);
Op op_call(CallParameters parameters);
Op op_return();
Op op_yield();
Op op_pushnode();
Op op_popnode();

#endif /* _ENGINE_H_ */
