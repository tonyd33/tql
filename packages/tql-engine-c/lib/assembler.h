#ifndef _ASSEMBLER_H_
#define _ASSEMBLER_H_

#include "program.h"

typedef uint64_t SymbolId;

struct Function;
struct AsmAxis;
struct AsmPredicate;
struct AsmJump;
struct AsmProbe;
struct AsmOp;
struct Assembler;

typedef struct Function Function;
typedef struct AsmAxis AsmAxis;
typedef struct AsmPredicate AsmPredicate;
typedef struct AsmJump AsmJump;
typedef struct AsmProbe AsmProbe;
typedef struct AsmOp AsmOp;
typedef struct Assembler Assembler;

typedef enum {
  ASMOP_NOOP,
  ASMOP_HALT,
  ASMOP_BRANCH,
  ASMOP_BIND,
  ASMOP_IF,
  ASMOP_YIELD,
  ASMOP_JMP,
  ASMOP_PROBE,
  ASMOP_PUSHNODE,
  ASMOP_POPNODE,

  ASMOP_END,
} AsmOpcode;

struct Function {
  SymbolId id;
  AsmOp *ops;
  uint32_t op_count;
  // FIXME: This doesn't really belong
  uint32_t placement;
};
DA_DEFINE(Function, Functions)

struct AsmAxis {
  AxisType axis_type;
  union {
    const char *field;
    VarId variable;
  } data;
};

struct AsmPredicate {
  PredicateType predicate_type;
  bool negate;
  union {
    struct {
      NodeExpression node_expression;
      const char *type;
    } typeeq;
    struct {
      NodeExpression node_expression;
      const char *text;
    } texteq;
  } data;
};

struct AsmJump {
  SymbolId symbol;
};

struct AsmProbe {
  ProbeMode mode;
  AsmJump jump;
};

struct AsmOp {
  AsmOpcode opcode;
  union {
    AsmAxis axis;
    AsmPredicate predicate;
    SymbolId variable;
    AsmProbe probe;
    AsmJump jump;
  } data;
};

struct Assembler {
  Functions functions;
  const TSLanguage *target;
};

const AsmOp asmop_noop(Assembler *asmb);
const AsmOp asmop_branch(Assembler *asmb, AsmAxis axis);
const AsmOp asmop_bind(Assembler *asmb, SymbolId id);
const AsmOp asmop_if(Assembler *asmb, AsmPredicate predicate);
const AsmOp asmop_probe(Assembler *asmb, AsmProbe probe);
const AsmOp asmop_halt(Assembler *asmb);
const AsmOp asmop_yield(Assembler *asmb);
const AsmOp asmop_pushnode(Assembler *asmb);
const AsmOp asmop_popnode(Assembler *asmb);
const AsmOp asmop_jump(Assembler *asmb, SymbolId id);

const AsmOp asmop_end(Assembler *asmb);
const AsmOp asmop_jump(Assembler *asmb, SymbolId id);
const AsmOp asmop_end(Assembler *asmb);

void assembler_init(Assembler *asmb, const TSLanguage *target);
void assembler_free(Assembler *asmb);

void assembler_register_function(Assembler *asmb, SymbolId id, const AsmOp *ops,
                                 uint32_t op_count);

Op *assembler_serialize(const Assembler *asmb, SymbolId entrypoint,
                        uint32_t *op_count);

#endif /* _ASSEMBLER_H_ */
