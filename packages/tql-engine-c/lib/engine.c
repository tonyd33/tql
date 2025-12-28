#include "engine.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 32768
#define ENGINE_STACK_CAPACITY 1024

struct NodeStack {
  NodeStack *prev;
  TSNode node;
  // Don't need this if we're arena-allocating this anyway...
  uint16_t ref_count;
};

typedef struct {
  enum {
    BOUNDARY_FAIL,
    BOUNDARY_MATCH,
    BOUNDARY_NEW,
  } type;
  union {
    Match match;
    LookaheadBoundary boundary;
  } data;
} BoundaryResult;

typedef struct {
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
} ExecutionResult;

NodeStack *node_stack_push(Engine *engine, NodeStack *stack, TSNode node) {
  NodeStack *new_stack = arena_alloc(engine->arena, sizeof(NodeStack));
  new_stack->prev = stack;
  new_stack->node = node;
  new_stack->ref_count = 1;
  if (stack != NULL) {
    stack->ref_count++;
  }
  return new_stack;
}

bool node_stack_pop(Engine *engine, NodeStack **stack, TSNode *node) {
  if (*stack == NULL) {
    return false;
  }
  *node = (*stack)->node;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return true;
}

void engine_init(Engine *engine, TSTree *ast, const char *source) {
  engine->ast = ast;
  engine->source = source;

  engine->ops = NULL;
  engine->arena = arena_new(ENGINE_HEAP_CAPACITY);
  engine->stk_cap = ENGINE_STACK_CAPACITY;
  engine->exc_ctx.exc_stk = malloc(engine->stk_cap * sizeof(Continuation));
  engine->exc_ctx.sp = engine->exc_ctx.exc_stk;

  engine->stats.step_count = 0;
}

void engine_free(Engine *engine) {
  engine->stats.step_count = 0;

  engine->exc_ctx.sp = NULL;
  free(engine->exc_ctx.exc_stk);
  engine->exc_ctx.exc_stk = NULL;
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

void engine_exec(Engine *engine) {
  Continuation root_continuation = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .node_stk = NULL,
  };
  bindings_init(&root_continuation.bindings);

  *engine->exc_ctx.sp = root_continuation;
}

static inline uint32_t get_jump_pc(uint32_t curr_pc, Jump jump) {
  return jump.relative ? curr_pc + jump.pc - 1 : jump.pc;
}

static ExecutionResult engine_step_exc_frame(Engine *engine,
                                             DelimitedExecution *del_exc,
                                             Continuation exc_frame) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  assert(!ts_node_is_null(exc_frame.node));
  while (exc_frame.pc < engine->op_count) {
    engine->stats.step_count++;

    Op op = engine->ops[exc_frame.pc++];
    // printf("id %u, pc %llu, opcode %d\n", exc_frame.id, exc_frame.pc - 1,
    //        op.opcode);
    switch (op.opcode) {
    case OP_NOOP:
      break;
    case OP_BRANCH: {
      Axis axis = op.data.axis;
      TSNodes branches;
      TSNodes_init(&branches);
      switch (axis.axis_type) {
      case AXIS_CHILD: {
        for (int i = ts_node_named_child_count(exc_frame.node) - 1; i >= 0;
             i--) {
          TSNodes_append(&branches, ts_node_named_child(exc_frame.node, i));
        }
        break;
      }
      case AXIS_DESCENDANT: {
        TSNodes desc_stack;
        TSNodes_init(&desc_stack);
        TSNodes_append(&desc_stack, exc_frame.node);
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
        for (int i = ts_node_named_child_count(exc_frame.node) - 1; i >= 0;
             i--) {
          const char *field_name_for_named_child =
              ts_node_field_name_for_named_child(exc_frame.node, i);
          if (field_name_for_named_child == NULL ||
              strcmp(field_name_for_named_child, field_name) != 0) {
            continue;
          }
          TSNodes_append(&branches, ts_node_named_child(exc_frame.node, i));
        }
        break;
      }
      }

      for (int i = branches.len - 1; i >= 0; i--) {
        TSNode branch = branches.data[i];
        Continuation frame = {
            .pc = exc_frame.pc,
            .node = branch,
            .node_stk = exc_frame.node_stk,
        };
        bindings_overlay(&frame.bindings, &exc_frame.bindings);
        *++del_exc->sp = frame;
      }
      TSNodes_free(&branches);
      return (ExecutionResult){
          .type = EXC_BRANCH,
      };
    } break;
    case OP_BIND: {
      bindings_insert(&exc_frame.bindings, op.data.var_id, exc_frame.node);
    } break;
    case OP_IF: {
      Predicate predicate = op.data.predicate;
      switch (predicate.predicate_type) {
      case PREDICATE_TYPEEQ: {
        NodeExpression left = predicate.data.typeeq.node_expression;
        TSSymbol right = predicate.data.typeeq.symbol;

        assert(left.node_expression_type == NODEEXPR_SELF &&
               "Only self supported");

        bool frame_done = ts_node_symbol(exc_frame.node) != right;
        frame_done = predicate.negate ? !frame_done : frame_done;
        if (frame_done) {
          return (ExecutionResult){.type = EXC_DROP};
        }
      } break;
      case PREDICATE_TEXTEQ: {
        NodeExpression left = predicate.data.texteq.node_expression;
        // FIXME: This is dangerous...
        const char *right = predicate.data.texteq.text;

        assert(left.node_expression_type == NODEEXPR_SELF &&
               "Only self supported");

        uint32_t start_byte = ts_node_start_byte(exc_frame.node);
        uint32_t end_byte = ts_node_end_byte(exc_frame.node);
        uint32_t buf_len = end_byte - start_byte;
        char buf[buf_len + 1];

        strncpy(buf, engine->source + start_byte, buf_len);
        buf[buf_len] = '\0';
        bool frame_done = strncmp(buf, right, buf_len) != 0;
        frame_done = predicate.negate ? !frame_done : frame_done;
        if (frame_done) {
          return (ExecutionResult){.type = EXC_DROP};
        }
      } break;
      }
    } break;
    case OP_PROBE: {
      Continuation next_exc_frame = {
          .pc = get_jump_pc(exc_frame.pc, op.data.probe.jump),
          .node = exc_frame.node,
          .node_stk = exc_frame.node_stk,
      };
      bindings_overlay(&next_exc_frame.bindings, &exc_frame.bindings);

      return (ExecutionResult){.type = EXC_BOUNDARY,
                               .data = {.boundary = {.mode = op.data.probe.mode,
                                                     .continuation = exc_frame,
                                                     .next = next_exc_frame}}};
    } break;
    case OP_HALT: {
      return (ExecutionResult){
          .type = EXC_DROP,
      };
    } break;
    case OP_YIELD: {
      return (ExecutionResult){.type = EXC_MATCH,
                               .data = {.match = {
                                            .node = exc_frame.node,
                                            .bindings = exc_frame.bindings,
                                        }}};
    } break;
    case OP_PUSHNODE: {
      exc_frame.node_stk =
          node_stack_push(engine, exc_frame.node_stk, exc_frame.node);
      break;
    }
    case OP_POPNODE: {
      if (!node_stack_pop(engine, &exc_frame.node_stk, &exc_frame.node)) {
        return (ExecutionResult){.type = EXC_ERR};
      }
    } break;
    case OP_JMP: {
      exc_frame.pc = get_jump_pc(exc_frame.pc, op.data.jump);
    } break;
    }
  }
  return (ExecutionResult){.type = EXC_ERR};
}

static BoundaryResult engine_step_exc_stack(Engine *engine,
                                            DelimitedExecution *del_exc) {
  while (del_exc->sp >= del_exc->exc_stk) {
    Continuation exc_frame = *del_exc->sp--;
    ExecutionResult result = engine_step_exc_frame(engine, del_exc, exc_frame);

    switch (result.type) {
    case EXC_DROP:
      continue;
    case EXC_BRANCH:
      continue;
    case EXC_MATCH:
      return (BoundaryResult){.type = BOUNDARY_MATCH,
                              .data = {.match = result.data.match}};
    case EXC_BOUNDARY: {
      *++del_exc->sp = result.data.boundary.next;
      LookaheadBoundary next_call_frame = {
          .call_mode = result.data.boundary.mode,
          .continuation = result.data.boundary.continuation,
          .del_exc = {.exc_stk = del_exc->sp, .sp = del_exc->sp},
      };

      return (BoundaryResult){.type = BOUNDARY_NEW,
                              .data = {.boundary = next_call_frame}};
    }
    case EXC_ERR:
      assert(false && "Bad program");
    }
    break;
  }
  return (BoundaryResult){.type = BOUNDARY_FAIL};
}

static bool engine_step_boundary(Engine *engine, LookaheadBoundary *boundary) {
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
    } break;
    }
  }
}

bool engine_next_match(Engine *engine, Match *match) {
  while (true) {
    BoundaryResult result = engine_step_exc_stack(engine, &engine->exc_ctx);

    switch (result.type) {
    case BOUNDARY_FAIL: {
      return false;
    } break;
    case BOUNDARY_MATCH: {
      *match = result.data.match;
      return true;
    } break;
    case BOUNDARY_NEW: {
      if (engine_step_boundary(engine, &result.data.boundary)) {
        *engine->exc_ctx.sp = result.data.boundary.continuation;
      } else {
        engine->exc_ctx.sp--;
      }
    } break;
    }
  }
}

Axis axis_field(TSFieldId field_id) {
  return (Axis){.axis_type = AXIS_FIELD, .data = {.field = field_id}};
}
Axis axis_child() { return (Axis){.axis_type = AXIS_CHILD}; }
Axis axis_descendant() { return (Axis){.axis_type = AXIS_DESCENDANT}; }

Predicate predicate_typeeq(NodeExpression ne, TSSymbol symbol) {
  return (Predicate){.predicate_type = PREDICATE_TYPEEQ,
                     .negate = false,
                     .data = {
                         .typeeq = {.node_expression = ne, .symbol = symbol},
                     }};
}
Predicate predicate_texteq(NodeExpression ne, const char *string) {
  return (Predicate){.predicate_type = PREDICATE_TEXTEQ,
                     .negate = false,
                     .data = {
                         .texteq = {.node_expression = ne, .text = string},
                     }};
}
Predicate predicate_negate(Predicate predicate) {
  predicate.negate = !predicate.negate;
  return predicate;
}

NodeExpression node_expression_self() {
  return (NodeExpression){.node_expression_type = NODEEXPR_SELF};
}

Op op_noop() { return (Op){.opcode = OP_NOOP}; }
Op op_branch(Axis axis) {
  return (Op){.opcode = OP_BRANCH, .data = {.axis = axis}};
}
Op op_bind(VarId var_id) {
  return (Op){.opcode = OP_BIND, .data = {.var_id = var_id}};
}
Op op_if(Predicate predicate) {
  return (Op){.opcode = OP_IF, .data = {.predicate = predicate}};
}
Op op_probe(Probe probe) {
  return (Op){.opcode = OP_PROBE, .data = {.probe = probe}};
}
Op op_halt() { return (Op){.opcode = OP_HALT}; }
Op op_yield() { return (Op){.opcode = OP_YIELD}; }
Op op_pushnode() { return (Op){.opcode = OP_PUSHNODE}; }
Op op_popnode() { return (Op){.opcode = OP_POPNODE}; }
Op op_jump(Jump jump) { return (Op){.opcode = OP_JMP, .data = {.jump = jump}}; }

Jump jump_relative(int32_t pc) { return (Jump){.relative = true, .pc = pc}; }
Jump jump_absolute(int32_t pc) { return (Jump){.relative = false, .pc = pc}; }

Probe probe_exists(Jump jump) {
  return (Probe){.mode = PROBE_EXISTS, .jump = jump};
}
Probe probe_not_exists(Jump jump) {
  return (Probe){.mode = PROBE_NOTEXISTS, .jump = jump};
}
