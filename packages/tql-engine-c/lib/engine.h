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
  PROBE_EXISTS,
  PROBE_NOTEXISTS,
} ProbeMode;

typedef struct {
  bool relative;
  int32_t pc;
} Jump;

typedef struct {
  ProbeMode mode;
  Jump jump;
} Probe;

typedef enum {
  /* Does nothing. */
  OP_NOOP,
  /* The current continuation stops. */
  OP_HALT,
  /* Creates continuations along an axis. */
  OP_BRANCH,
  /* Binds the current node into a variable. */
  OP_BIND,
  /* Does nothing if the predicate passes, otherwise halts the program. */
  OP_IF,
  /* Yield the current node and bindings. */
  OP_YIELD,
  /* Jump to another instruction. */
  OP_JMP,
  /* Save the continuation, jump, and execute the rest of the program. Yielding
     or failure to yield will either restore the continuation or drop it, based
     on the probe mode. */
  OP_PROBE,
  /* Push the current node onto the continuation's local stack. */
  OP_PUSHNODE,
  /* Pop the node from the continuation's local stack. */
  OP_POPNODE,
} Opcode;

typedef struct {
  Opcode opcode;
  union {
    Axis axis;
    Predicate predicate;
    VarId var_id;
    Jump jump;
    Probe probe;
  } data;
} Op;

DA_DEFINE(Op, Ops)
DA_DEFINE(Match, Matches)

struct NodeStack;
typedef struct NodeStack NodeStack;

typedef struct {
  uint32_t pc;
  TSNode node;
  Bindings bindings;
  NodeStack *node_stk;
} Continuation;

typedef struct DelimitedExecution {
  Continuation *exc_stk;
  Continuation *sp;
} DelimitedExecution;

typedef struct LookaheadBoundary LookaheadBoundary;
struct LookaheadBoundary {
  ProbeMode call_mode;
  DelimitedExecution del_exc;
  Continuation continuation;
};
typedef struct {
  uint32_t step_count;
} EngineStats;

typedef struct {
  TSTree *ast;
  const char *source;

  Op *ops;
  uint32_t op_count;
  Arena *arena;
  uint32_t stk_cap;
  DelimitedExecution exc_ctx;

  EngineStats stats;
} Engine;

void engine_init(Engine *engine, TSTree *ast, const char *source);
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

Jump jump_relative(int32_t pc);
Jump jump_absolute(int32_t pc);

Probe probe_exists(Jump jump);
Probe probe_not_exists(Jump jump);

Op op_noop();
Op op_branch(Axis axis);
Op op_bind(VarId var_id);
Op op_if(Predicate predicate);
Op op_probe(Probe probe);
Op op_halt();
Op op_yield();
Op op_pushnode();
Op op_popnode();
Op op_jump(Jump jump);

#endif /* _ENGINE_H_ */
