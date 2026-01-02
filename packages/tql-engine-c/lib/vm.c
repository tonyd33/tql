#include "vm.h"
#include "arena.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 65536
#define ENGINE_STACK_CAPACITY 4096

DA_DEFINE(TSNode, TSNodes, ts_nodes)

typedef TSNode TQLValue;

struct Binding;
struct Bindings;
struct Continuation;
struct DelimitedExecution;
struct LookaheadBoundary;
struct Vm;
struct VmStats;
struct NodeStack;
struct PCStack;

typedef struct Binding Binding;
typedef struct Bindings Bindings;
typedef struct Match Match;
typedef struct Continuation Continuation;
typedef struct DelimitedExecution DelimitedExecution;
typedef struct LookaheadBoundary LookaheadBoundary;
typedef struct Vm Vm;
typedef struct VmStats VmStats;
typedef struct NodeStack NodeStack;
typedef struct PCStack PCStack;
typedef struct BoundaryResult BoundaryResult;
typedef struct ContinuationResult ContinuationResult;

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

struct NodeStack {
  NodeStack *prev;
  TSNode node;
  // Don't need this if we're arena-allocating this anyway...
  uint16_t ref_count;
};

struct PCStack {
  PCStack *prev;
  uint32_t pc;
  // Don't need this if we're arena-allocating this anyway...
  uint16_t ref_count;
};

struct Continuation {
  uint32_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack *node_stk;
  PCStack *pc_stk;
};

struct DelimitedExecution {
  Continuation *cnt_stk;
  Continuation *sp;
};

struct LookaheadBoundary {
  ProbeMode call_mode;
  DelimitedExecution del_exc;
  Continuation continuation;
};

struct BoundaryResult {
  enum {
    BOUNDARY_FAIL,
    BOUNDARY_MATCH,
    BOUNDARY_NEW,
  } type;
  union {
    Match match;
    LookaheadBoundary boundary;
  } data;
};

struct ContinuationResult {
  enum {
    EXC_ERR,
    EXC_DROP,
    EXC_MATCH,
    EXC_BRANCH,
    EXC_BOUNDARY,
  } type;
  union {
    Match match;
    struct {
      ProbeMode mode;
      Continuation continuation;
      Continuation next;
    } boundary;
  } data;
};

struct Vm {
  TSTree *ast;
  const char *source;

  Arena *arena;
  uint32_t stk_cap;
  DelimitedExecution del_exc;
  TSNodes branch_buffer[2];

  VmStats stats;
  Program program;
};

// op helpers {{{
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
const inline Op op_call(Jump jump) {
  return (Op){.opcode = OP_CALL, .data = {.jump = jump}};
}
const inline Op op_ret() { return (Op){.opcode = OP_RET}; }

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
// }}}

TQLValue *bindings_get(Bindings *bindings, VarId variable) {
  while (bindings != NULL) {
    if (bindings->binding.variable == variable) {
      return &bindings->binding.value;
    }
    bindings = bindings->parent;
  }
  return NULL;
}

// FIXME: Allocating in the arena is just an excuse for bad memory management...
Bindings *bindings_insert(const Vm *vm, Bindings *bindings, VarId variable,
                          TQLValue value) {
  Bindings *overlay = arena_alloc(vm->arena, sizeof(Bindings));
  overlay->ref_count = 1;
  overlay->parent = bindings;
  overlay->binding = (Binding){
      .variable = variable,
      .value = value,
  };
  if (bindings != NULL) {
    bindings->ref_count++;
  }
  return overlay;
}

void bindings_free(const Vm *vm, Bindings *bindings) {}

NodeStack *node_stack_push(const Vm *vm, NodeStack *stack, TSNode node) {
  NodeStack *new_stack = arena_alloc(vm->arena, sizeof(NodeStack));
  new_stack->prev = stack;
  new_stack->node = node;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool node_stack_pop(const Vm *vm, NodeStack **stack, TSNode *node) {
  if (*stack == NULL) {
    return false;
  }
  *node = (*stack)->node;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void node_stack_free(const Vm *vm, NodeStack *stack) {}

PCStack *pc_stack_push(const Vm *vm, PCStack *stack, uint32_t pc) {
  PCStack *new_stack = arena_alloc(vm->arena, sizeof(PCStack));
  new_stack->prev = stack;
  new_stack->pc = pc;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool pc_stack_pop(const Vm *vm, PCStack **stack, uint32_t *pc) {
  if (*stack == NULL) {
    return false;
  }
  *pc = (*stack)->pc;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void pc_stack_free(const Vm *vm, PCStack *stack) {}

Vm *vm_new(TSTree *ast, const char *source) {
  Vm *vm = malloc(sizeof(Vm));
  vm->ast = ast;
  vm->source = source;

  vm->arena = arena_new(ENGINE_HEAP_CAPACITY);
  vm->stk_cap = ENGINE_STACK_CAPACITY;
  vm->del_exc.cnt_stk = malloc(vm->stk_cap * sizeof(Continuation));
  vm->del_exc.sp = vm->del_exc.cnt_stk;

  vm->stats = (VmStats){.step_count = 0, .boundaries_encountered = 0};

  ts_nodes_init(&vm->branch_buffer[0]);
  ts_nodes_init(&vm->branch_buffer[1]);

  return vm;
}

void vm_free(Vm *vm) {
  ts_nodes_deinit(&vm->branch_buffer[1]);
  ts_nodes_deinit(&vm->branch_buffer[0]);
  for (Continuation *cnt = vm->del_exc.cnt_stk; cnt <= vm->del_exc.sp; cnt++) {
    bindings_free(vm, cnt->bindings);
    cnt->bindings = NULL;
  }

  vm->del_exc.sp = NULL;
  free(vm->del_exc.cnt_stk);
  vm->del_exc.cnt_stk = NULL;
  vm->stk_cap = 0;

  arena_free(vm->arena);
  vm->arena = NULL;
  vm->source = NULL;
  vm->ast = NULL;

  free(vm);
}

static inline Op vm_get_op(const Vm *vm, uint32_t pc) {
  return *((Op *)(vm->program.data + vm->program.entrypoint) + pc);
}

static inline VmStats *vm_stats_mut(const Vm *vm) {
  return (VmStats *)&(vm->stats); // HACK
}

const VmStats *vm_stats(const Vm *vm) { return &(vm->stats); }

void vm_exec(Vm *vm) {
  Continuation root_continuation = {
      .pc = 0,
      .node = ts_tree_root_node(vm->ast),
      .node_stk = NULL,
      .pc_stk = NULL,
      .bindings = NULL,
  };

  *vm->del_exc.sp = root_continuation;
}

static inline uint32_t get_jump_pc(uint32_t curr_pc, Jump jump) {
  return jump.relative ? curr_pc + jump.pc : jump.pc;
}

static ContinuationResult vm_step_continuation(/* const */ Vm *vm,
                                               DelimitedExecution *del_exc,
                                               Continuation *cnt) {
  const TSLanguage *language = ts_tree_language(vm->ast);
  assert(!ts_node_is_null(cnt->node));
  VmStats *stats = vm_stats_mut(vm);

  while (cnt->pc < (vm->program.endpoint - vm->program.entrypoint)) {
    stats->step_count++;

    // Op op = vm->ops[cnt->pc++];
    Op op = vm_get_op(vm, cnt->pc++);
    // char buf[1024];
    // uint32_t start_byte = ts_node_start_byte(cnt->node);
    // uint32_t end_byte = ts_node_end_byte(cnt->node);
    // uint32_t buf_len = end_byte - start_byte;
    //
    // strncpy(buf, engine->source + start_byte, buf_len);
    // buf[buf_len] = '\0';
    // printf("pc %u, opcode %d, on node %s\n", cnt->pc - 1, op.opcode, buf);
    switch (op.opcode) {
    case OP_NOOP:
      break;
    case OP_BRANCH: {
      // TODO: Allow the continuation to store the info on the axis so that it
      // can be continued during axis enumeration
      Axis axis = op.data.axis;
      TSNodes *branches = &vm->branch_buffer[0];
      branches->len = 0;
      switch (axis.axis_type) {
      case AXIS_CHILD: {
        ts_nodes_reserve(branches, ts_node_named_child_count(cnt->node));
        for (int i = ts_node_named_child_count(cnt->node) - 1; i >= 0; i--) {
          ts_nodes_append(branches, ts_node_named_child(cnt->node, i));
        }
        break;
      }
      case AXIS_DESCENDANT: {
        TSNodes *desc_stack = &vm->branch_buffer[1];
        ts_nodes_reserve(branches, ts_node_descendant_count(cnt->node));
        ts_nodes_reserve(desc_stack, ts_node_descendant_count(cnt->node));
        ts_nodes_append(desc_stack, cnt->node);
        TSNode curr;
        TSNode child;
        while (desc_stack->len > 0) {
          curr = desc_stack->data[--desc_stack->len];
          for (int i = 0; i < ts_node_named_child_count(curr); i++) {
            child = ts_node_named_child(curr, i);
            ts_nodes_append(desc_stack, child);
            ts_nodes_append(branches, child);
          }
        }
        break;
      }
      case AXIS_FIELD: {
        TSFieldId field_id = axis.data.field;
        ts_nodes_reserve(branches, ts_node_named_child_count(cnt->node));
        const char *field_name =
            ts_language_field_name_for_id(language, field_id);
        for (int i = ts_node_named_child_count(cnt->node) - 1; i >= 0; i--) {
          const char *field_name_for_named_child =
              ts_node_field_name_for_named_child(cnt->node, i);
          if (field_name_for_named_child == NULL ||
              strcmp(field_name_for_named_child, field_name) != 0) {
            continue;
          }
          ts_nodes_append(branches, ts_node_named_child(cnt->node, i));
        }
        break;
      }
      case AXIS_VAR: {
        TSNode *node = bindings_get(cnt->bindings, axis.data.variable);
        if (node == NULL) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        ts_nodes_append(branches, *node);
      } break;
      }

      for (uint32_t i = 0; i < branches->len; i++) {
        TSNode branch = branches->data[i];
        Continuation new_cnt = {
            .pc = cnt->pc,
            .node = branch,
            .node_stk = cnt->node_stk,
            .pc_stk = cnt->pc_stk,
            .bindings = cnt->bindings,
        };
        *++del_exc->sp = new_cnt;
      }
      stats->max_branching_factor = branches->len > stats->max_branching_factor
                                        ? branches->len
                                        : stats->max_branching_factor;
      stats->total_branching += branches->len;
      branches->len = 0;
      return (ContinuationResult){
          .type = EXC_BRANCH,
      };
    } break;
    case OP_BIND: {
      cnt->bindings =
          bindings_insert(vm, cnt->bindings, op.data.var_id, cnt->node);
    } break;
    case OP_IF: {
      Predicate predicate = op.data.predicate;
      switch (predicate.predicate_type) {
      case PREDICATE_TYPEEQ: {
        NodeExpression left = predicate.data.typeeq.node_expression;
        TSSymbol right = predicate.data.typeeq.symbol;

        assert(left.node_expression_type == NODEEXPR_SELF &&
               "Only self supported");

        bool frame_done = ts_node_symbol(cnt->node) != right;
        frame_done = predicate.negate ? !frame_done : frame_done;
        if (frame_done) {
          return (ContinuationResult){.type = EXC_DROP};
        }
      } break;
      case PREDICATE_TEXTEQ: {
        NodeExpression left = predicate.data.texteq.node_expression;
        // FIXME: This is dangerous...
        const char *right = predicate.data.texteq.text;

        assert(left.node_expression_type == NODEEXPR_SELF &&
               "Only self supported");

        uint32_t start_byte = ts_node_start_byte(cnt->node);
        uint32_t end_byte = ts_node_end_byte(cnt->node);
        uint32_t buf_len = end_byte - start_byte;
        char buf[buf_len + 1];

        strncpy(buf, vm->source + start_byte, buf_len);
        buf[buf_len] = '\0';
        bool frame_done = strncmp(buf, right, buf_len) != 0;
        frame_done = predicate.negate ? !frame_done : frame_done;
        if (frame_done) {
          return (ContinuationResult){.type = EXC_DROP};
        }
      } break;
      }
    } break;
    case OP_PROBE: {
      Continuation next_cnt = {
          .pc = get_jump_pc(cnt->pc - 1, op.data.probe.jump),
          .node = cnt->node,
          .node_stk = cnt->node_stk,
          .pc_stk = cnt->pc_stk,
          .bindings = cnt->bindings,
      };

      return (ContinuationResult){
          .type = EXC_BOUNDARY,
          .data = {.boundary = {.mode = op.data.probe.mode,
                                .continuation = *cnt,
                                .next = next_cnt}}};
    } break;
    case OP_HALT: {
      return (ContinuationResult){
          .type = EXC_DROP,
      };
    } break;
    case OP_YIELD: {
      return (ContinuationResult){.type = EXC_MATCH,
                                  .data = {.match = {
                                               .node = cnt->node,
                                               .bindings = cnt->bindings,
                                           }}};
    } break;
    case OP_PUSH: {
      switch (op.data.push_target) {
      case PUSH_NODE:
        cnt->node_stk = node_stack_push(vm, cnt->node_stk, cnt->node);
        break;
      case PUSH_PC:
        cnt->pc_stk = pc_stack_push(vm, cnt->pc_stk, cnt->pc);
        break;
      }
    } break;
    case OP_POP: {
      switch (op.data.push_target) {
      case PUSH_NODE:
        if (!node_stack_pop(vm, &cnt->node_stk, &cnt->node)) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        break;
      case PUSH_PC:
        if (!pc_stack_pop(vm, &cnt->pc_stk, &cnt->pc)) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        break;
      }
    } break;
    case OP_JMP: {
      cnt->pc = get_jump_pc(cnt->pc - 1, op.data.jump);
    } break;
    case OP_CALL:
      // TODO: We should push bindings
      cnt->pc_stk = pc_stack_push(vm, cnt->pc_stk, cnt->pc);
      cnt->pc = get_jump_pc(cnt->pc - 1, op.data.jump);
      break;
    case OP_RET:
      // TODO: We should pop bindings
      if (!pc_stack_pop(vm, &cnt->pc_stk, &cnt->pc)) {
        return (ContinuationResult){.type = EXC_ERR};
      }
      break;
    }
  }
  return (ContinuationResult){.type = EXC_ERR};
}

static BoundaryResult vm_step_exc_stack(/* const */ Vm *vm,
                                        DelimitedExecution *del_exc) {
  VmStats *stats = vm_stats_mut(vm);
  while (del_exc->sp >= del_exc->cnt_stk) {
    stats->max_stack_size =
        (del_exc->sp - vm->del_exc.cnt_stk) + 1 > stats->max_stack_size
            ? (del_exc->sp - vm->del_exc.cnt_stk) + 1
            : stats->max_stack_size;
    Continuation *cnt = del_exc->sp--;
    ContinuationResult result = vm_step_continuation(vm, del_exc, cnt);

    switch (result.type) {
    case EXC_DROP:
    case EXC_BRANCH:
      // FIXME: Need to deinit the continuation, which is tricky...
      continue;
    case EXC_MATCH:
      return (BoundaryResult){.type = BOUNDARY_MATCH,
                              .data = {.match = result.data.match}};
    case EXC_BOUNDARY: {
      *++del_exc->sp = result.data.boundary.next;
      LookaheadBoundary next_call_frame = {
          .call_mode = result.data.boundary.mode,
          .continuation = result.data.boundary.continuation,
          .del_exc = {.cnt_stk = del_exc->sp, .sp = del_exc->sp},
      };

      return (BoundaryResult){.type = BOUNDARY_NEW,
                              .data = {.boundary = next_call_frame}};
    }
    case EXC_ERR:
      fprintf(stderr, "Program failed on pc %u\n", cnt->pc);
      assert(false && "Bad program");
    }
    break;
  }
  return (BoundaryResult){.type = BOUNDARY_FAIL};
}

static bool vm_step_boundary(/* const */ Vm *vm, LookaheadBoundary *boundary) {
  VmStats *stats = vm_stats_mut(vm);
  while (true) {
    BoundaryResult result = vm_step_exc_stack(vm, &boundary->del_exc);
    switch (result.type) {
    case BOUNDARY_FAIL: {
      return boundary->call_mode == PROBE_NOTEXISTS;
    } break;
    case BOUNDARY_MATCH: {
      return boundary->call_mode == PROBE_EXISTS;
    } break;
    case BOUNDARY_NEW: {
      stats->boundaries_encountered++;

      if (vm_step_boundary(vm, &result.data.boundary)) {
        *boundary->del_exc.sp = result.data.boundary.continuation;
      } else {
        Continuation *cnt = vm->del_exc.sp;
        bindings_free(vm, cnt->bindings);
        cnt->bindings = NULL;

        bindings_free(vm, result.data.boundary.continuation.bindings);
        result.data.boundary.continuation.bindings = NULL;

        boundary->del_exc.sp--;
      }
    } break;
    }
  }
}

bool vm_next_match(Vm *vm, Match *match) {
  while (true) {
    BoundaryResult result = vm_step_exc_stack(vm, &vm->del_exc);

    switch (result.type) {
    case BOUNDARY_FAIL: {
      return false;
    } break;
    case BOUNDARY_MATCH: {
      *match = result.data.match;
      return true;
    } break;
    case BOUNDARY_NEW: {
      vm->stats.boundaries_encountered++;

      if (vm_step_boundary(vm, &result.data.boundary)) {
        *vm->del_exc.sp = result.data.boundary.continuation;
      } else {
        Continuation *cnt = vm->del_exc.sp;
        bindings_free(vm, cnt->bindings);
        cnt->bindings = NULL;

        bindings_free(vm, result.data.boundary.continuation.bindings);
        result.data.boundary.continuation.bindings = NULL;

        vm->del_exc.sp--;
      }
    } break;
    }
  }
}

void vm_load(Vm *vm, Program program) { vm->program = program; }
