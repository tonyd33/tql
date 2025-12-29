#include "assembler.h"

void function_init(Function *fn, SymbolId id, const AsmOp *ops,
                   uint32_t op_count) {
  fn->id = id;
  fn->op_count = op_count;
  fn->ops = malloc(sizeof(AsmOp) * op_count);
  memcpy(fn->ops, ops, sizeof(AsmOp) * op_count);
}

void function_free(Function *fn) {
  free(fn->ops);
  fn->ops = NULL;
  fn->op_count = 0;
  fn->id = 0;
}

void assembler_init(Assembler *asmb, const TSLanguage *target) {
  asmb->target = target;
  Functions_init(&asmb->functions);
}

void assembler_free(Assembler *asmb) {
  for (int i = 0; i < asmb->functions.len; i++) {
    function_free(&asmb->functions.data[i]);
  }
  Functions_free(&asmb->functions);
  asmb->target = NULL;
}

static inline const Function *assembler_lookup_function(const Assembler *asmb,
                                                        SymbolId id) {
  for (int i = 0; i < asmb->functions.len; i++) {
    if (asmb->functions.data[i].id == id) {
      return &asmb->functions.data[i];
    }
  }
  return NULL;
}

static inline const Op assemble_op(const Assembler *asmb, const AsmOp *op) {
  switch (op->opcode) {
  case ASMOP_NOOP:
    return op_noop();
  case ASMOP_HALT:
    return op_halt();
  case ASMOP_BRANCH: {
    Axis axis;
    switch (op->data.axis.axis_type) {
    case AXIS_CHILD:
      axis = axis_child();
      break;
    case AXIS_DESCENDANT:
      axis = axis_descendant();
      break;
    case AXIS_FIELD:
      axis = axis_field(
          ts_language_field_id_for_name(asmb->target, op->data.axis.data.field,
                                        strlen(op->data.axis.data.field)));
      break;
    case AXIS_VAR:
      axis = (Axis){.axis_type = AXIS_VAR,
                    .data = {.variable = op->data.axis.data.variable}};
      break;
    }
    return op_branch(axis);
  }
  case ASMOP_BIND:
    return op_bind(op->data.variable);
  case ASMOP_IF: {
    Predicate pred;
    switch (op->data.predicate.predicate_type) {
    case PREDICATE_TEXTEQ:
      pred = predicate_texteq(op->data.predicate.data.texteq.node_expression,
                              op->data.predicate.data.texteq.text);
      break;
    case PREDICATE_TYPEEQ:
      pred = predicate_typeeq(
          op->data.predicate.data.typeeq.node_expression,
          ts_language_symbol_for_name(
              asmb->target, op->data.predicate.data.typeeq.type,
              strlen(op->data.predicate.data.typeeq.type), true));
      break;
    }
    pred = op->data.predicate.negate ? predicate_negate(pred) : pred;
    return op_if(pred);
  }
  case ASMOP_YIELD:
    return op_yield();
  case ASMOP_JMP: {
    const Function *fn = assembler_lookup_function(asmb, op->data.jump.symbol);
    assert(fn != NULL);
    Jump jump = jump_absolute(fn->placement);
    return op_jump(jump);
  }
  case ASMOP_PROBE: {
    const Function *fn =
        assembler_lookup_function(asmb, op->data.probe.jump.symbol);
    assert(fn != NULL);
    Jump jump = jump_absolute(fn->placement);
    return op_probe((Probe){.mode = op->data.probe.mode, .jump = jump});
  }
  case ASMOP_PUSHNODE:
    return op_pushnode();
  case ASMOP_POPNODE:
    return op_popnode();
  case ASMOP_END:
    return op_noop();
  }
}

Op *assembler_serialize(const Assembler *asmb, SymbolId entrypoint,
                        uint32_t *op_count) {
  assert(asmb->functions.len > 0);
  *op_count = 0;

  uint32_t entrypoint_idx = 0;
  for (int i = 0; i < asmb->functions.len; i++) {
    if (asmb->functions.data[i].id == entrypoint) {
      entrypoint_idx = i;
      break;
    }
  }
  Function temp = asmb->functions.data[0];
  asmb->functions.data[0] = asmb->functions.data[entrypoint_idx];
  asmb->functions.data[entrypoint_idx] = temp;

  for (int i = 0; i < asmb->functions.len; i++) {
    asmb->functions.data[i].placement = *op_count;
    *op_count += asmb->functions.data[i].op_count;
  }

  Op *ops = malloc(sizeof(Op) * (*op_count));
  uint32_t cursor = 0;
  for (int i = 0; i < asmb->functions.len; i++) {
    Function fn = asmb->functions.data[i];
    for (int j = 0; j < fn.op_count; j++) {
      ops[cursor++] = assemble_op(asmb, &fn.ops[j]);
    }
  }

  return ops;
}

const inline AsmOp asmop_noop(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_NOOP};
}
const inline AsmOp asmop_branch(Assembler *asmb, AsmAxis axis) {
  return (AsmOp){.opcode = ASMOP_BRANCH, .data = {.axis = axis}};
}
const inline AsmOp asmop_bind(Assembler *asmb, SymbolId symbol) {
  return (AsmOp){.opcode = ASMOP_BIND, .data = {.variable = symbol}};
}
const inline AsmOp asmop_if(Assembler *asmb, AsmPredicate predicate) {
  return (AsmOp){.opcode = ASMOP_IF, .data = {.predicate = predicate}};
}
const inline AsmOp asmop_probe(Assembler *asmb, AsmProbe probe) {
  return (AsmOp){.opcode = ASMOP_PROBE, .data = {.probe = probe}};
}
const inline AsmOp asmop_halt(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_HALT};
}
const inline AsmOp asmop_yield(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_YIELD};
}
const inline AsmOp asmop_pushnode(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_PUSHNODE};
}
const inline AsmOp asmop_popnode(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_POPNODE};
}
const inline AsmOp asmop_jump(Assembler *asmb, SymbolId id) {
  return (AsmOp){.opcode = ASMOP_JMP, .data = {.jump = {.symbol = id}}};
}
const inline AsmOp asmop_end(Assembler *asmb) {
  return (AsmOp){.opcode = ASMOP_END};
}

void assembler_register_function(Assembler *asmb, SymbolId id, const AsmOp *ops,
                                 uint32_t op_count) {
  Function fn;
  function_init(&fn, id, ops, op_count);
  Functions_append(&asmb->functions, fn);
}
