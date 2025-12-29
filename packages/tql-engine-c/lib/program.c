#include "program.h"
#include <stdio.h>

const inline Axis axis_field(TSFieldId field_id) {
  return (Axis){.axis_type = AXIS_FIELD, .data = {.field = field_id}};
}
const inline Axis axis_child() { return (Axis){.axis_type = AXIS_CHILD}; }
const inline Axis axis_descendant() {
  return (Axis){.axis_type = AXIS_DESCENDANT};
}

const inline Predicate predicate_typeeq(NodeExpression ne, TSSymbol symbol) {
  return (Predicate){.predicate_type = PREDICATE_TYPEEQ,
                     .negate = false,
                     .data = {
                         .typeeq = {.node_expression = ne, .symbol = symbol},
                     }};
}
const inline Predicate predicate_texteq(NodeExpression ne, const char *string) {
  return (Predicate){.predicate_type = PREDICATE_TEXTEQ,
                     .negate = false,
                     .data = {
                         .texteq = {.node_expression = ne, .text = string},
                     }};
}
const inline Predicate predicate_negate(Predicate predicate) {
  predicate.negate = !predicate.negate;
  return predicate;
}

const inline NodeExpression node_expression_self() {
  return (NodeExpression){.node_expression_type = NODEEXPR_SELF};
}

const inline Op op_noop() { return (Op){.opcode = OP_NOOP}; }
const inline Op op_branch(Axis axis) {
  return (Op){.opcode = OP_BRANCH, .data = {.axis = axis}};
}
const inline Op op_bind(VarId var_id) {
  return (Op){.opcode = OP_BIND, .data = {.var_id = var_id}};
}
const inline Op op_if(Predicate predicate) {
  return (Op){.opcode = OP_IF, .data = {.predicate = predicate}};
}
const inline Op op_probe(Probe probe) {
  return (Op){.opcode = OP_PROBE, .data = {.probe = probe}};
}
const inline Op op_halt() { return (Op){.opcode = OP_HALT}; }
const inline Op op_yield() { return (Op){.opcode = OP_YIELD}; }
const inline Op op_pushnode() {
  return (Op){.opcode = OP_PUSH, .data = {.push_target = PUSH_NODE}};
}
const inline Op op_popnode() {
  return (Op){.opcode = OP_POP, .data = {.push_target = PUSH_NODE}};
}
const inline Op op_pushpc() {
  return (Op){.opcode = OP_PUSH, .data = {.push_target = PUSH_PC}};
}
const inline Op op_poppc() {
  return (Op){.opcode = OP_POP, .data = {.push_target = PUSH_PC}};
}
const inline Op op_jump(Jump jump) {
  return (Op){.opcode = OP_JMP, .data = {.jump = jump}};
}

const inline Jump jump_relative(int32_t pc) {
  return (Jump){.relative = true, .pc = pc};
}
const inline Jump jump_absolute(int32_t pc) {
  return (Jump){.relative = false, .pc = pc};
}

const inline Probe probe_exists(Jump jump) {
  return (Probe){.mode = PROBE_EXISTS, .jump = jump};
}
const inline Probe probe_not_exists(Jump jump) {
  return (Probe){.mode = PROBE_NOTEXISTS, .jump = jump};
}

