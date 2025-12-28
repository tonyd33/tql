#include "engine.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 32768
#define ENGINE_STACK_CAPACITY 1024

struct NodeStack {
  NodeStack *prev;
  TSNode node;
  // Possibly don't need this
  uint16_t ref_count;
};

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

TSNode node_stack_pop(Engine *engine, NodeStack **stack) {
  assert(*stack != NULL);
  TSNode node = (*stack)->node;
  (*stack)->ref_count--;
  *stack = (*stack)->prev;
  return node;
}

typedef enum {
  EXC_FAIL2,
  EXC_MATCH2,
  EXC_CONTINUE2,
  EXC_RET2,
} ExecutionResult2;

void engine_init(Engine *engine) {
  engine->ast = NULL;
  engine->source = NULL;
  engine->step_count = 0;
  Ops_init(&engine->ops);
  engine->arena = arena_new(ENGINE_HEAP_CAPACITY);
  engine->stack_cap = ENGINE_STACK_CAPACITY;
  engine->exc_ctx.exc_stack =
      malloc(engine->stack_cap * sizeof(ExecutionStack));
  engine->exc_ctx.sp = engine->exc_ctx.exc_stack;
}

void engine_free(Engine *engine) {
  engine->exc_ctx.sp = NULL;
  free(engine->exc_ctx.exc_stack);
  engine->exc_ctx.exc_stack = NULL;
  engine->stack_cap = 0;
  arena_free(engine->arena);
  Ops_free(&engine->ops);
  engine->source = NULL;
  engine->ast = NULL;
}

void engine_load_ast(Engine *engine, TSTree *ast) { engine->ast = ast; }

void engine_load_source(Engine *engine, const char *source) {
  engine->source = source;
}

void engine_load_program(Engine *engine, Op *ops, uint32_t op_count) {
  Ops_reserve(&engine->ops, op_count);
  engine->ops.len = op_count;
  memcpy(engine->ops.data, ops, sizeof(Op) * op_count);
}

void engine_exec(Engine *engine) {
  ExecutionFrame root_exc_frame = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .node_stack = NULL,
  };
  bindings_init(&root_exc_frame.bindings);

  *engine->exc_ctx.sp = root_exc_frame;
}

static uint32_t exc_id = 0;

typedef struct {
  enum {
    BOUNDARY_FAIL,
    BOUNDARY_MATCH,
    BOUNDARY_NEW,
  } type;
  union {
    Match match;
    CallBoundary boundary;
  } data;
} BoundaryResult;

typedef struct {
  enum {
    EXC_DROP,
    EXC_MATCH,
    EXC_BRANCH,
    EXC_BOUNDARY,
  } type;
  union {
    Match match;
    struct {
      CallMode mode;
      ExecutionFrame continuation;
      ExecutionFrame next;
    } boundary;
  } data;
} ExecutionResult;

// FIXME: Ugh, passing in the frames like this is kinda cursed.
// Consider allowing this to just append to an execution stack directly.
static ExecutionResult engine_step_exc_frame(Engine *engine,
                                             ExecutionFrame exc_frame,
                                             ExecutionStack *exc_stack) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  assert(!ts_node_is_null(exc_frame.node));
  while (exc_frame.pc < engine->ops.len) {
    engine->step_count++;

    Op op = engine->ops.data[exc_frame.pc++];
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
        ExecutionFrame frame = {
            .id = exc_id++,
            .pc = exc_frame.pc,
            .node = branch,
            .node_stack = exc_frame.node_stack,
        };
        bindings_overlay(&frame.bindings, &exc_frame.bindings);
        ExecutionStack_append(exc_stack, frame);
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
    case OP_CALL: {
      ExecutionFrame next_exc_frame = {
          .id = exc_id++,
          .pc = op.data.call_parameters.relative
                    ? exc_frame.pc + op.data.call_parameters.pc - 1
                    : op.data.call_parameters.pc,
          .node = exc_frame.node,
          .node_stack = NULL};
      bindings_overlay(&next_exc_frame.bindings, &exc_frame.bindings);

      return (ExecutionResult){
          .type = EXC_BOUNDARY,
          .data = {.boundary = {.mode = op.data.call_parameters.mode,
                                .continuation = exc_frame,
                                .next = next_exc_frame}}};
    } break;
    case OP_RETURN: {
      return (ExecutionResult){
          .type = EXC_DROP,
      };
    }
    case OP_YIELD: {
      return (ExecutionResult){.type = EXC_MATCH,
                               .data = {.match = {
                                            .node = exc_frame.node,
                                            .bindings = exc_frame.bindings,
                                        }}};
    } break;
    case OP_PUSHNODE: {
      exc_frame.node_stack =
          node_stack_push(engine, exc_frame.node_stack, exc_frame.node);
      break;
    }
    case OP_POPNODE: {
      exc_frame.node = node_stack_pop(engine, &exc_frame.node_stack);
      break;
    }
    }
  }
  // FIXME: Make this error
  return (ExecutionResult){.type = EXC_DROP};
}

static BoundaryResult engine_step_exc_stack(Engine *engine,
                                            ExecutionFrame *boundary) {
  ExecutionStack stack;
  ExecutionStack_init(&stack);
  while (engine->exc_ctx.sp >= boundary) {
    ExecutionFrame exc_frame = *engine->exc_ctx.sp--;
    ExecutionResult result = engine_step_exc_frame(engine, exc_frame, &stack);

    switch (result.type) {
    case EXC_DROP:
      continue;
    case EXC_MATCH:
      ExecutionStack_free(&stack);
      return (BoundaryResult){.type = BOUNDARY_MATCH,
                              .data = {.match = result.data.match}};
    case EXC_BRANCH: {
      for (int i = 0; i < stack.len; i++) {
        *++engine->exc_ctx.sp = stack.data[i];
      }
      stack.len = 0;
    } break;
    case EXC_BOUNDARY: {
      *++engine->exc_ctx.sp = result.data.boundary.next;
      CallBoundary next_call_frame = {
          .call_mode = result.data.boundary.mode,
          .continuation = result.data.boundary.continuation,
          .boundary = engine->exc_ctx.sp,
      };

      ExecutionStack_free(&stack);
      return (BoundaryResult){.type = BOUNDARY_NEW,
                              .data = {.boundary = next_call_frame}};
    }
    }
  }
  ExecutionStack_free(&stack);
  return (BoundaryResult){.type = BOUNDARY_FAIL};
}

static bool engine_step_boundary(Engine *engine, CallBoundary *boundary) {
  while (true) {
    BoundaryResult result = engine_step_exc_stack(engine, boundary->boundary);
    switch (result.type) {
    case BOUNDARY_FAIL: {
      return boundary->call_mode == CALLMODE_NOTEXISTS;
    } break;
    case BOUNDARY_MATCH: {
      return boundary->call_mode == CALLMODE_EXISTS;
    } break;
    case BOUNDARY_NEW: {
      bool ok = engine_step_boundary(engine, &result.data.boundary);
      if (ok) {
        engine->exc_ctx.sp = result.data.boundary.boundary - 1;
        *++engine->exc_ctx.sp = result.data.boundary.continuation;
      }
    } break;
    }
  }
}

bool engine_next_match(Engine *engine, Match *match) {
  CallBoundary cb_stack[1024];
  uint32_t cb_count = 0;

  while (true) {
    BoundaryResult result =
        engine_step_exc_stack(engine, engine->exc_ctx.exc_stack);

    switch (result.type) {
    case BOUNDARY_FAIL: {
      return false;
    } break;
    case BOUNDARY_MATCH: {
      *match = result.data.match;
      return true;
    } break;
    case BOUNDARY_NEW: {
      bool ok = engine_step_boundary(engine, &result.data.boundary);
      if (ok) {
        engine->exc_ctx.sp = result.data.boundary.boundary - 1;
        *++engine->exc_ctx.sp = result.data.boundary.continuation;
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
Op op_call(CallParameters parameters) {
  return (Op){.opcode = OP_CALL, .data = {.call_parameters = parameters}};
}
Op op_return() { return (Op){.opcode = OP_RETURN}; }
Op op_yield() { return (Op){.opcode = OP_YIELD}; }
Op op_pushnode() { return (Op){.opcode = OP_PUSHNODE}; }
Op op_popnode() { return (Op){.opcode = OP_POPNODE}; }
