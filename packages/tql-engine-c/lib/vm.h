#ifndef _VM_H_
#define _VM_H_

#include "ds.h"
#include <tree_sitter/api.h>

typedef uint64_t VarId;
typedef uint64_t Symbol;

typedef struct Vm Vm;
typedef struct VmSymbol VmSymbol;
typedef struct VmStats VmStats;
typedef struct Op Op;
typedef struct Axis Axis;
typedef struct Predicate Predicate;
typedef struct Jump Jump;
typedef struct Probe Probe;
typedef struct Push Push;
typedef struct Match Match;
typedef struct Bindings Bindings;
typedef struct Program Program;
typedef struct Binding Binding;

typedef enum {
  /* Does nothing. */
  OP_NOOP,
  /* The current continuation stops. */
  OP_HALT,
  /* Creates continuations along an axis. */
  OP_BRANCH,
  /* Duplicates the current continuation at an instruction. */
  OP_DUP,
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
  /* Push onto continuation's local stack. */
  OP_PUSH,
  /* Pop from continuation's local stack. */
  OP_POP,
  /* Call a function. */
  OP_CALL,
  /* Return from a function. */
  OP_RET,
} Opcode;

typedef enum {
  PREDICATE_TEXTEQ,
  PREDICATE_TYPEEQ,
} PredicateType;

typedef enum {
  PROBE_EXISTS,
  PROBE_NOTEXISTS,
} ProbeMode;

typedef enum {
  AXIS_CHILD,
  AXIS_DESCENDANT,
  AXIS_FIELD,
  AXIS_VAR,
} AxisType;

typedef enum { PUSH_NODE, PUSH_PC, PUSH_BND } PushTarget;

typedef TSNode TQLValue;

struct Axis {
  AxisType axis_type;
  union {
    TSFieldId field;
    VarId variable;
  } data;
};

struct Predicate {
  PredicateType predicate_type;
  bool negate;
  union {
    struct {
      TSSymbol symbol;
    } typeeq;
    struct {
      // TODO: Create a symbol lookup table and use a reference to the symbol
      // id here. This is currently dangerous, since the string is not owned by
      // the vm.
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
    PushTarget push_target;
  } data;
};
DA_DEFINE(Op, Ops, ops)

struct Binding {
  VarId variable;
  TQLValue value;
};

struct Bindings {
  Bindings *parent;
  Binding binding;
  // Don't need this if we're arena-allocating this anyway...
  uint16_t ref_count;
};

struct VmStats {
  uint32_t step_count;
  uint32_t boundaries_encountered;
  uint32_t total_branching;
  uint32_t max_branching_factor;
  uint32_t max_stack_size;
};

struct Match {
  TSNode node;
  const Bindings *bindings;
};

typedef enum TQLSymbolType {
  SYMBOL_VARIABLE,
  SYMBOL_FIELD,
  SYMBOL_FUNCTION,
} TQLSymbolType;

typedef struct {
  Symbol id;
  TQLSymbolType type;
  StringSlice slice;
  // FIXME: This doesn't belong
  uint32_t placement;
} SymbolEntry;
DA_DEFINE(SymbolEntry, SymbolTable, symbol_table)

struct Program {
  uint64_t version;
  const TSLanguage *target_language;
  SymbolTable *symtab;
  Ops *instrs;
};
Program *program_new(uint32_t version, const TSLanguage *target_language,
                     const SymbolTable *symtab, const Ops *instrs);
void program_free(Program *program);

Vm *vm_new(TSTree *ast, const char *source);
void vm_load(Vm *vm, const Program *program);
void vm_free(Vm *vm);

void vm_exec(Vm *vm);
bool vm_next_match(Vm *vm, Match *match);

VmStats vm_stats(const Vm *vm);

Axis axis_field(TSFieldId field_id);
Axis axis_child(void);
Axis axis_descendant(void);

Predicate predicate_typeeq(TSSymbol symbol);
Predicate predicate_texteq(const char *string);
Predicate predicate_negate(Predicate predicate);

Jump jump_relative(int32_t pc);
Jump jump_absolute(int32_t pc);

Probe probe_exists(Jump jump);
Probe probe_not_exists(Jump jump);

Op op_noop(void);
Op op_branch(Axis axis);
Op op_dup(Jump jump);
Op op_bind(VarId var_id);
Op op_if(Predicate predicate);
Op op_probe(Probe probe);
Op op_halt(void);
Op op_yield(void);
Op op_pushnode(void);
Op op_popnode(void);
Op op_pushpc(void);
Op op_poppc(void);
Op op_pushbnd(void);
Op op_popbnd(void);
Op op_jump(Jump jump);
Op op_call(Jump jump);
Op op_ret(void);

#endif /* _VM_H_ */
