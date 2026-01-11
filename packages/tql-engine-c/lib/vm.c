#include "vm.h"
#include "arena.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 65536
#define ENGINE_STACK_CAPACITY 4096

DA_DEFINE(TSNode, TSNodes, ts_nodes)

typedef struct Continuation Continuation;
typedef struct DelimitedExecution DelimitedExecution;
typedef struct LookaheadBoundary LookaheadBoundary;
typedef struct Vm Vm;
typedef struct VmStats VmStats;
typedef struct NodeStack NodeStack;
typedef struct PCStack PCStack;
typedef struct BoundaryResult BoundaryResult;
typedef struct ContinuationResult ContinuationResult;
typedef struct BindingsStack BindingsStack;

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

struct BindingsStack {
  BindingsStack *prev;
  Bindings *bindings;
  // Don't need this if we're arena-allocating this anyway...
  uint16_t ref_count;
};

struct Continuation {
  uint32_t pc;
  TSNode node;
  Bindings *bindings;
  NodeStack *node_stk;
  PCStack *pc_stk;
  BindingsStack *bindings_stk;
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
    struct {
      Match match;
      Continuation cnt;
    } match;
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
  const TQLProgram *program;
};

// op helpers {{{
inline Axis axis_field(TSFieldId field_id) {
  return (Axis){.axis_type = AXIS_FIELD, .data = {.field = field_id}};
}
inline Axis axis_child() { return (Axis){.axis_type = AXIS_CHILD}; }
inline Axis axis_descendant() { return (Axis){.axis_type = AXIS_DESCENDANT}; }

inline Predicate predicate_typeeq(TSSymbol symbol) {
  return (Predicate){.predicate_type = PREDICATE_TYPEEQ,
                     .negate = false,
                     .data = {
                         .typeeq = {.symbol = symbol},
                     }};
}
inline Predicate predicate_texteq(const char *string) {
  return (Predicate){.predicate_type = PREDICATE_TEXTEQ,
                     .negate = false,
                     .data = {
                         .texteq = {.text = string},
                     }};
}
inline Predicate predicate_negate(Predicate predicate) {
  predicate.negate = !predicate.negate;
  return predicate;
}

inline Op op_noop() { return (Op){.opcode = OP_NOOP}; }
inline Op op_traverse(Axis axis) {
  return (Op){.opcode = OP_TRAVERSE, .data = {.axis = axis}};
}
inline Op op_fork(Jump jump) {
  return (Op){.opcode = OP_FORK, .data = {.jump = jump}};
}
inline Op op_bind(Symbol var_id) {
  return (Op){.opcode = OP_BIND, .data = {.var_id = var_id}};
}
inline Op op_asn_currnode(Symbol var_id) {
  return (Op){
      .opcode = OP_ASN,
      .data = {.asn = {.source = TQL_OP_ASN_CURRNODE, .variable = var_id}}};
}
inline Op op_asn_symbol(Symbol var_id, Symbol symbol) {
  return (Op){.opcode = OP_ASN,
              .data = {.asn = {.source = TQL_OP_ASN_SYMBOL,
                               .variable = var_id,
                               .data = {.symbol = symbol}}}};
}
inline Op op_if(Predicate predicate) {
  return (Op){.opcode = OP_IF, .data = {.predicate = predicate}};
}
inline Op op_probe(Probe probe) {
  return (Op){.opcode = OP_PROBE, .data = {.probe = probe}};
}
inline Op op_halt() { return (Op){.opcode = OP_HALT}; }
inline Op op_yield() { return (Op){.opcode = OP_YIELD}; }
inline Op op_pushnode() {
  return (Op){.opcode = OP_PUSH, .data = {.push_target = PUSH_NODE}};
}
inline Op op_popnode() {
  return (Op){.opcode = OP_POP, .data = {.push_target = PUSH_NODE}};
}
inline Op op_pushpc() {
  return (Op){.opcode = OP_PUSH, .data = {.push_target = PUSH_PC}};
}
inline Op op_poppc() {
  return (Op){.opcode = OP_POP, .data = {.push_target = PUSH_PC}};
}
inline Op op_pushbnd() {
  return (Op){.opcode = OP_PUSH, .data = {.push_target = PUSH_BND}};
}
inline Op op_popbnd() {
  return (Op){.opcode = OP_POP, .data = {.push_target = PUSH_BND}};
}
inline Op op_jump(Jump jump) {
  return (Op){.opcode = OP_JMP, .data = {.jump = jump}};
}
inline Op op_call(Jump jump) {
  return (Op){.opcode = OP_CALL, .data = {.jump = jump}};
}
inline Op op_ret() { return (Op){.opcode = OP_RET}; }

inline Jump jump_relative(int32_t pc) {
  return (Jump){.relative = true, .pc = pc};
}
inline Jump jump_absolute(int32_t pc) {
  return (Jump){.relative = false, .pc = pc};
}

inline Probe probe_exists(Jump jump) {
  return (Probe){.mode = PROBE_EXISTS, .jump = jump};
}
inline Probe probe_not_exists(Jump jump) {
  return (Probe){.mode = PROBE_NOTEXISTS, .jump = jump};
}
// }}}

TQLValue *bindings_get(Bindings *bindings, Symbol variable) {
  while (bindings != NULL) {
    if (bindings->binding.variable == variable) {
      return &bindings->binding.value;
    }
    bindings = bindings->parent;
  }
  return NULL;
}

// FIXME: Allocating in the arena is just an excuse for bad memory management...
Bindings *bindings_insert(const Vm *vm, Bindings *bindings, Symbol variable,
                          TQLValue value) {
  // (minor optimization) If the current binding is the variable itself, we can
  // split at the first parent that isn't equal.
  // IMPROVE: We should really rethink this because it doesn't help in the case
  // where different bindings are interleaved.
  while (bindings != NULL && bindings->binding.variable == variable) {
    bindings = bindings->parent;
  }
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

BindingsStack *bindings_stack_push(const Vm *vm, BindingsStack *stack,
                                   Bindings *bindings) {
  BindingsStack *new_stack = arena_alloc(vm->arena, sizeof(BindingsStack));
  new_stack->prev = stack;
  new_stack->bindings = bindings;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool bindings_stack_pop(const Vm *vm, BindingsStack **stack,
                        Bindings **bindings) {
  if (*stack == NULL) {
    return false;
  }
  *bindings = (*stack)->bindings;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void bindings_stack_free(const Vm *vm, BindingsStack *stack) {
  // Ignore unused
  assert(vm != NULL);
  assert(stack == NULL || stack != NULL);
}

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
  assert(pc < vm->program->instrs->len);
  return vm->program->instrs->data[pc];
}

static inline VmStats *vm_stats_mut(const Vm *vm) {
  return (VmStats *)&(vm->stats); // HACK
}

VmStats vm_stats(const Vm *vm) { return vm->stats; }

void vm_exec(Vm *vm) {
  Continuation root_continuation = {
      .pc = 0,
      .node = ts_tree_root_node(vm->ast),
      .node_stk = NULL,
      .pc_stk = NULL,
      .bindings_stk = NULL,
      .bindings = NULL,
  };

  *vm->del_exc.sp = root_continuation;
}

static inline uint32_t get_jump_pc(uint32_t curr_pc, Jump jump) {
  return jump.relative ? curr_pc + jump.pc : (uint32_t)jump.pc;
}

static ContinuationResult vm_step_continuation(/* const */ Vm *vm,
                                               DelimitedExecution *del_exc,
                                               Continuation *cnt) {
  const TSLanguage *language = ts_tree_language(vm->ast);
  assert(!ts_node_is_null(cnt->node));
  VmStats *stats = vm_stats_mut(vm);

  while (cnt->pc < vm->program->instrs->len) {
    stats->step_count++;

    Op op = vm_get_op(vm, cnt->pc++);
    switch (op.opcode) {
    case OP_NOOP:
      break;
    case OP_TRAVERSE: {
      /* IMPROVE: Allow the continuation to store the info on the axis so that
       * it can be continued during axis enumeration.
       *
       * What this would likely look like is we store the following into
       * continuations:
       * (is_traversing, axis_type, axis_index)
       *
       * And then each time we hit a continuation that's traversing,
       * check to see if it has any more nodes to traverse.
       *
       * If so, push itself back to the continuation stack and also push
       * the next node. Handling this would look similar to OP_FORK in terms of
       * how it affects the stack.
       *
       * This will give a huge improvement to memory, making memory complexity
       * scale O(depth) instead of O(branching factor * depth) when paired with
       * proper initialization/deinitialization of continuations.
       */
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
          for (uint32_t i = 0; i < ts_node_named_child_count(curr); i++) {
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
        TQLValue *value = bindings_get(cnt->bindings, axis.data.variable);
        if (value == NULL) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        if (value->type != TQL_VALUE_NODE) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        ts_nodes_append(branches, value->data.node);
      } break;
      }

      for (uint32_t i = 0; i < branches->len; i++) {
        TSNode branch = branches->data[i];
        Continuation new_cnt = {
            .pc = cnt->pc,
            .node = branch,
            .node_stk = cnt->node_stk,
            .bindings_stk = cnt->bindings_stk,
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
    case OP_FORK: {
      *++del_exc->sp = (Continuation){
          .pc = cnt->pc,
          .node = cnt->node,
          .node_stk = cnt->node_stk,
          .bindings_stk = cnt->bindings_stk,
          .pc_stk = cnt->pc_stk,
          .bindings = cnt->bindings,
      };
      *++del_exc->sp = (Continuation){
          .pc = get_jump_pc(cnt->pc - 1, op.data.jump),
          .node = cnt->node,
          .node_stk = cnt->node_stk,
          .bindings_stk = cnt->bindings_stk,
          .pc_stk = cnt->pc_stk,
          .bindings = cnt->bindings,
      };
      return (ContinuationResult){
          .type = EXC_BRANCH,
      };
    } break;
    case OP_BIND: {
      cnt->bindings = bindings_insert(
          vm, cnt->bindings, op.data.var_id,
          (TQLValue){.type = TQL_VALUE_NODE, .data = {.node = cnt->node}});
    } break;
    case OP_ASN: {
      switch (op.data.asn.source) {
      case TQL_OP_ASN_CURRNODE:
        cnt->bindings = bindings_insert(
            vm, cnt->bindings, op.data.asn.variable,
            (TQLValue){.type = TQL_VALUE_NODE, .data = {.node = cnt->node}});
        break;
      case TQL_OP_ASN_SYMBOL:
        cnt->bindings = bindings_insert(
            vm, cnt->bindings, op.data.asn.variable,
            (TQLValue){.type = TQL_VALUE_SYMBOL,
                       .data = {.symbol = op.data.asn.data.symbol}});
        break;
      }
    } break;
    case OP_IF: {
      Predicate predicate = op.data.predicate;
      switch (predicate.predicate_type) {
      case PREDICATE_TYPEEQ: {
        TSSymbol right = predicate.data.typeeq.symbol;

        bool frame_done = ts_node_symbol(cnt->node) != right;
        frame_done = predicate.negate ? !frame_done : frame_done;
        if (frame_done) {
          return (ContinuationResult){.type = EXC_DROP};
        }
      } break;
      case PREDICATE_TEXTEQ: {
        const char *right = predicate.data.texteq.text;

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
          .bindings_stk = cnt->bindings_stk,
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
      case PUSH_BND:
        cnt->bindings_stk =
            bindings_stack_push(vm, cnt->bindings_stk, cnt->bindings);
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
      case PUSH_BND:
        if (!bindings_stack_pop(vm, &cnt->bindings_stk, &cnt->bindings)) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        break;
      }
    } break;
    case OP_JMP: {
      cnt->pc = get_jump_pc(cnt->pc - 1, op.data.jump);
    } break;
    case OP_CALL:
      cnt->pc_stk = pc_stack_push(vm, cnt->pc_stk, cnt->pc);
      cnt->pc = get_jump_pc(cnt->pc - 1, op.data.jump);
      break;
    case OP_RET:
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
      /* Here, we may need to also return the current continuation in order to
       * allow restoring continuation-local values like bindings from a
       * lookahead boundary.
       * Design-wise, I'm not sure if this is the right choice though.
       */
      return (BoundaryResult){
          .type = BOUNDARY_MATCH,
          .data = {.match = {.match = result.data.match, .cnt = *cnt}}};
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
      fprintf(stderr, "Program failed on pc %u\n", cnt->pc - 1);
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
      // FIXME: Not sure if this makes sense... it does work though.
      boundary->continuation.bindings = result.data.match.cnt.bindings;
      return boundary->call_mode == PROBE_EXISTS;
    } break;
    case BOUNDARY_NEW: {
      stats->boundaries_encountered++;

      // FIXME: Do not recurse
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
      *match = result.data.match.match;
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

void vm_load(Vm *vm, const TQLProgram *program) { vm->program = program; }

TQLProgram *tql_program_new(uint32_t version, const TSLanguage *target_language,
                            const SymbolTable *symtab, const Ops *instrs) {
  TQLProgram *program = malloc(sizeof(TQLProgram));
  program->version = version;
  program->target_language = target_language;
  program->symtab = symbol_table_new();
  symbol_table_clone(program->symtab, symtab);
  program->instrs = ops_new();
  ops_clone(program->instrs, instrs);
  return program;
}

void tql_program_free(TQLProgram *program) {
  symbol_table_free(program->symtab);
  program->symtab = NULL;

  ops_free(program->instrs);
  program->instrs = NULL;

  program->target_language = NULL;

  free(program);
}
