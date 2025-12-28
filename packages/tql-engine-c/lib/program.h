#ifndef _PROGRAM_H_
#define _PROGRAM_H_

#include <tree_sitter/api.h>

typedef uint64_t VarId;

struct Axis;
struct NodeExpression;
struct Predicate;
struct Jump;
struct Probe;
struct Op;
struct AssemblerOp;
struct ProgramBuilder;

typedef uint64_t FunctionId;
typedef struct Match Match;
typedef struct Axis Axis;
typedef struct NodeExpression NodeExpression;
typedef struct Predicate Predicate;
typedef struct Jump Jump;
typedef struct Probe Probe;
typedef struct Op Op;
typedef struct AssemblerOp AssemblerOp;
typedef struct ProgramBuilder ProgramBuilder;

typedef enum AxisType {
  AXIS_CHILD,
  AXIS_DESCENDANT,
  AXIS_FIELD,
} AxisType;

typedef enum PredicateType {
  PREDICATE_TEXTEQ,
  PREDICATE_TYPEEQ,
} PredicateType;

typedef enum NodeExpressionType {
  NODEEXPR_SELF,
  NODEEXPR_VAR,
} NodeExpressionType;

typedef enum ProbeMode {
  PROBE_EXISTS,
  PROBE_NOTEXISTS,
} ProbeMode;

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

struct Axis {
  AxisType axis_type;
  union {
    TSFieldId field;
  } data;
};

struct NodeExpression {
  NodeExpressionType node_expression_type;
  union {
    VarId var_id;
  } operand;
};

struct Predicate {
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
};

struct Jump {
  bool relative;
  int32_t pc;
};

struct Probe {
  ProbeMode mode;
  Jump jump;
};

struct Op {
  Opcode opcode;
  union {
    Axis axis;
    Predicate predicate;
    VarId var_id;
    Jump jump;
    Probe probe;
  } data;
};

const Axis axis_field(TSFieldId field_id);
const Axis axis_child();
const Axis axis_descendant();

const Predicate predicate_typeeq(NodeExpression ne, TSSymbol symbol);
const Predicate predicate_texteq(NodeExpression ne, const char *string);
const Predicate predicate_negate(Predicate predicate);

const NodeExpression node_expression_self();

const Jump jump_relative(int32_t pc);
const Jump jump_absolute(int32_t pc);

const Probe probe_exists(Jump jump);
const Probe probe_not_exists(Jump jump);

const Op op_noop();
const Op op_branch(Axis axis);
const Op op_bind(VarId var_id);
const Op op_if(Predicate predicate);
const Op op_probe(Probe probe);
const Op op_halt();
const Op op_yield();
const Op op_pushnode();
const Op op_popnode();
const Op op_jump(Jump jump);

const AssemblerOp asmop_of(Op op);
const AssemblerOp asmop_jump(FunctionId id);
const AssemblerOp asmop_probe(FunctionId id, ProbeMode mode);
const AssemblerOp asmop_end();

void assembler_init(ProgramBuilder *pb);
void assembler_free(ProgramBuilder *pb);

void assembler_define_function(ProgramBuilder *pb, FunctionId id,
                               const AssemblerOp *ops);

Op *program_builder_serialize(ProgramBuilder *pb);

#endif /* _PROGRAM_H_ */
