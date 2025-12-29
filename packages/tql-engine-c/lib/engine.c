#include "engine.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 65536
#define ENGINE_STACK_CAPACITY 4096

struct Binding;
struct NodeStack;
struct PCStack;
struct BoundaryResult;
struct ContinuationResult;

typedef struct Binding Binding;
typedef struct NodeStack NodeStack;
typedef struct PCStack PCStack;
typedef struct BoundaryResult BoundaryResult;
typedef struct ContinuationResult ContinuationResult;

DA_DEFINE(TSNode, TSNodes)

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
Bindings *bindings_insert(const Engine *engine, Bindings *bindings,
                          VarId variable, TQLValue value) {
  Bindings *overlay = arena_alloc(engine->arena, sizeof(Bindings));
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

void bindings_free(const Engine *engine, Bindings *bindings) {}

NodeStack *node_stack_push(const Engine *engine, NodeStack *stack,
                           TSNode node) {
  NodeStack *new_stack = arena_alloc(engine->arena, sizeof(NodeStack));
  new_stack->prev = stack;
  new_stack->node = node;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool node_stack_pop(const Engine *engine, NodeStack **stack, TSNode *node) {
  if (*stack == NULL) {
    return false;
  }
  *node = (*stack)->node;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void node_stack_free(const Engine *engine, NodeStack *stack) {}

PCStack *pc_stack_push(const Engine *engine, PCStack *stack, uint32_t pc) {
  PCStack *new_stack = arena_alloc(engine->arena, sizeof(PCStack));
  new_stack->prev = stack;
  new_stack->pc = pc;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool pc_stack_pop(const Engine *engine, PCStack **stack, uint32_t *pc) {
  if (*stack == NULL) {
    return false;
  }
  *pc = (*stack)->pc;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void pc_stack_free(const Engine *engine, PCStack *stack) {}

void engine_init(Engine *engine, TSTree *ast, const char *source) {
  engine->ast = ast;
  engine->source = source;

  engine->ops = NULL;
  engine->arena = arena_new(ENGINE_HEAP_CAPACITY);
  engine->stk_cap = ENGINE_STACK_CAPACITY;
  engine->del_exc.cnt_stk = malloc(engine->stk_cap * sizeof(Continuation));
  engine->del_exc.sp = engine->del_exc.cnt_stk;

  engine->stats = (EngineStats){.step_count = 0, .boundaries_encountered = 0};
}

void engine_free(Engine *engine) {
  for (Continuation *cnt = engine->del_exc.cnt_stk; cnt <= engine->del_exc.sp;
       cnt++) {
    bindings_free(engine, cnt->bindings);
    cnt->bindings = NULL;
  }

  engine->del_exc.sp = NULL;
  free(engine->del_exc.cnt_stk);
  engine->del_exc.cnt_stk = NULL;
  engine->stk_cap = 0;

  arena_free(engine->arena);
  engine->arena = NULL;
  free(engine->ops);
  engine->ops = NULL;
  engine->source = NULL;
  engine->ast = NULL;
}

void engine_load_program(Engine *engine, Op *ops, uint32_t op_count) {
  engine->op_count = op_count;
  engine->ops = malloc(sizeof(Op) * op_count);
  memcpy(engine->ops, ops, sizeof(Op) * op_count);
}

static inline EngineStats *engine_stats_mut(const Engine *engine) {
  return (EngineStats *)&(engine->stats); // HACK
}

void engine_exec(Engine *engine) {
  Continuation root_continuation = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .node_stk = NULL,
      .bindings = NULL,
  };

  *engine->del_exc.sp = root_continuation;
}

static inline uint32_t get_jump_pc(uint32_t curr_pc, Jump jump) {
  return jump.relative ? curr_pc + jump.pc : jump.pc;
}

static ContinuationResult engine_step_continuation(const Engine *engine,
                                                   DelimitedExecution *del_exc,
                                                   Continuation *cnt) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  assert(!ts_node_is_null(cnt->node));
  EngineStats *stats = engine_stats_mut(engine);

  while (cnt->pc < engine->op_count) {
    stats->step_count++;

    Op op = engine->ops[cnt->pc++];
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
      TSNodes branches;
      TSNodes_init(&branches);
      switch (axis.axis_type) {
      case AXIS_CHILD: {
        for (int i = ts_node_named_child_count(cnt->node) - 1; i >= 0; i--) {
          TSNodes_append(&branches, ts_node_named_child(cnt->node, i));
        }
        break;
      }
      case AXIS_DESCENDANT: {
        TSNodes desc_stack;
        TSNodes_init(&desc_stack);
        TSNodes_append(&desc_stack, cnt->node);
        TSNode curr;
        TSNode child;
        while (desc_stack.len > 0) {
          curr = desc_stack.data[--desc_stack.len];
          for (int i = 0; i < ts_node_named_child_count(curr); i++) {
            child = ts_node_named_child(curr, i);
            TSNodes_append(&desc_stack, child);
            TSNodes_append(&branches, child);
          }
        }

        TSNodes_free(&desc_stack);
        break;
      }
      case AXIS_FIELD: {
        TSFieldId field_id = axis.data.field;
        const char *field_name =
            ts_language_field_name_for_id(language, field_id);
        for (int i = ts_node_named_child_count(cnt->node) - 1; i >= 0; i--) {
          const char *field_name_for_named_child =
              ts_node_field_name_for_named_child(cnt->node, i);
          if (field_name_for_named_child == NULL ||
              strcmp(field_name_for_named_child, field_name) != 0) {
            continue;
          }
          TSNodes_append(&branches, ts_node_named_child(cnt->node, i));
        }
        break;
      }
      case AXIS_VAR: {
        TSNode *node = bindings_get(cnt->bindings, axis.data.variable);
        if (node == NULL) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        TSNodes_append(&branches, *node);
      } break;
      }

      for (uint32_t i = 0; i < branches.len; i++) {
        TSNode branch = branches.data[i];
        Continuation new_cnt = {
            .pc = cnt->pc,
            .node = branch,
            .node_stk = cnt->node_stk,
            .bindings = cnt->bindings,
        };
        *++del_exc->sp = new_cnt;
      }
      stats->max_branching_factor = branches.len > stats->max_branching_factor
                                        ? branches.len
                                        : stats->max_branching_factor;
      stats->total_branching += branches.len;
      TSNodes_free(&branches);
      return (ContinuationResult){
          .type = EXC_BRANCH,
      };
    } break;
    case OP_BIND: {
      cnt->bindings =
          bindings_insert(engine, cnt->bindings, op.data.var_id, cnt->node);
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

        strncpy(buf, engine->source + start_byte, buf_len);
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
        cnt->node_stk = node_stack_push(engine, cnt->node_stk, cnt->node);
        break;
      case PUSH_PC:
        cnt->pc_stk = pc_stack_push(engine, cnt->pc_stk, cnt->pc);
        break;
      }
    } break;
    case OP_POP: {
      switch (op.data.push_target) {
      case PUSH_NODE:
        if (!node_stack_pop(engine, &cnt->node_stk, &cnt->node)) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        break;
      case PUSH_PC:
        if (!pc_stack_pop(engine, &cnt->pc_stk, &cnt->pc)) {
          return (ContinuationResult){.type = EXC_ERR};
        }
        break;
      }
    } break;
    case OP_JMP: {
      cnt->pc = get_jump_pc(cnt->pc - 1, op.data.jump);
    } break;
    }
  }
  return (ContinuationResult){.type = EXC_ERR};
}

static BoundaryResult engine_step_exc_stack(const Engine *engine,
                                            DelimitedExecution *del_exc) {
  EngineStats *stats = engine_stats_mut(engine);
  while (del_exc->sp >= del_exc->cnt_stk) {
    stats->max_stack_size =
        (del_exc->sp - engine->del_exc.cnt_stk) + 1 > stats->max_stack_size
            ? (del_exc->sp - engine->del_exc.cnt_stk) + 1
            : stats->max_stack_size;
    Continuation *cnt = del_exc->sp--;
    ContinuationResult result = engine_step_continuation(engine, del_exc, cnt);

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

static bool engine_step_boundary(const Engine *engine,
                                 LookaheadBoundary *boundary) {
  EngineStats *stats = engine_stats_mut(engine);
  while (true) {
    BoundaryResult result = engine_step_exc_stack(engine, &boundary->del_exc);
    switch (result.type) {
    case BOUNDARY_FAIL: {
      return boundary->call_mode == PROBE_NOTEXISTS;
    } break;
    case BOUNDARY_MATCH: {
      return boundary->call_mode == PROBE_EXISTS;
    } break;
    case BOUNDARY_NEW: {
      assert(false && "Dont get here yet");
      stats->boundaries_encountered++;
    } break;
    }
  }
}

bool engine_next_match(Engine *engine, Match *match) {
  while (true) {
    BoundaryResult result = engine_step_exc_stack(engine, &engine->del_exc);

    switch (result.type) {
    case BOUNDARY_FAIL: {
      return false;
    } break;
    case BOUNDARY_MATCH: {
      *match = result.data.match;
      return true;
    } break;
    case BOUNDARY_NEW: {
      engine->stats.boundaries_encountered++;

      if (engine_step_boundary(engine, &result.data.boundary)) {
        *engine->del_exc.sp = result.data.boundary.continuation;
      } else {
        Continuation *cnt = engine->del_exc.sp;
        bindings_free(engine, cnt->bindings);
        cnt->bindings = NULL;

        bindings_free(engine, result.data.boundary.continuation.bindings);
        result.data.boundary.continuation.bindings = NULL;

        engine->del_exc.sp--;
      }
    } break;
    }
  }
}
