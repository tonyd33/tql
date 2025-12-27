#include "engine.h"
#include <stdio.h>

#define ENGINE_HEAP_CAPACITY 32768

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
  EXC_FAIL,
  EXC_MATCH,
  EXC_CONTINUE,
  EXC_RET,
} ExecutionResult;

void engine_init(Engine *engine) {
  engine->ast = NULL;
  engine->source = NULL;
  engine->step_count = 0;
  Ops_init(&engine->ops);
  CallStack_init(&engine->call_stack);
  engine->arena = arena_new(ENGINE_HEAP_CAPACITY);
}

void engine_free(Engine *engine) {
  arena_free(engine->arena);
  CallStack_free(&engine->call_stack);
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
  CallFrame root_call_frame = {
      .call_mode = CALLMODE_PASSTHROUGH,
      .has_continuation = false,
  };

  ExecutionFrame root_exc_frame = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .node_stack = NULL,
  };
  bindings_init(&root_exc_frame.bindings);

  ExecutionStack_init(&root_call_frame.exc_stack);
  ExecutionStack_append(&root_call_frame.exc_stack, root_exc_frame);
  CallStack_append(&engine->call_stack, root_call_frame);
}

/*
 * Termination of this function means either:
 * - EXC_MATCH: We found a result, and it has been stored in match. The current
 *   execution stack may be resumed to find more results.
 * - EXC_FAIL: All execution frames in the stack were exhausted without any
 *   results.
 * - EXC_CONTINUE: We must continue in a separate execution frame.
 * - EXC_RET: An execution has been finished via a return.
 * FIXME: This is so bad!!!
 */
static ExecutionResult engine_step_execution_frame(Engine *engine,
                                                   ExecutionStack *exc_stack,
                                                   Match *match,
                                                   ExecutionFrame *out) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  while (exc_stack->len > 0) {
    ExecutionFrame exc_frame = exc_stack->data[--exc_stack->len];
    bool frame_done = false;

    do {
      if (exc_frame.pc >= engine->ops.len) {
        frame_done = true;
        break;
      }

      engine->step_count++;

      Op op = engine->ops.data[exc_frame.pc];
      // printf("opcode %d, pc %llu\n", op.opcode, exc_frame.pc);
      switch (op.opcode) {
      case OP_NOOP: {
        exc_frame.pc++;
        break;
      }
      case OP_BRANCH: {
        Axis axis = op.data.axis;
        uint64_t next_pc = exc_frame.pc + 1;
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
        default: {
          assert(false && "Unknown axis");
        }
        }

        for (int i = branches.len - 1; i >= 0; i--) {
          TSNode branch = branches.data[i];

          Bindings overlay;
          bindings_overlay(&overlay, &exc_frame.bindings);
          ExecutionFrame frame = {
              .pc = next_pc,
              .node = branch,
              .bindings = overlay,
              .node_stack = exc_frame.node_stack,
          };
          ExecutionStack_append(exc_stack, frame);
        }

        frame_done = true;
        TSNodes_free(&branches);
        break;
      }
      case OP_IF: {
        Predicate predicate = op.data.predicate;
        switch (predicate.predicate_type) {
        case PREDICATE_TYPEEQ: {
          NodeExpression left = predicate.data.typeeq.node_expression;
          TSSymbol right = predicate.data.typeeq.symbol;

          assert(left.node_expression_type == NODEEXPR_SELF &&
                 "Only self supported");

          frame_done = ts_node_symbol(exc_frame.node) != right;
          frame_done = predicate.negate ? !frame_done : frame_done;
          break;
        }
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
          frame_done = strncmp(buf, right, buf_len) != 0;
          frame_done = predicate.negate ? !frame_done : frame_done;
          break;
        }
        default: {
          assert(false && "Unknown predicate type");
          break;
        }
        }

        exc_frame.pc++;
        break;
      }
      case OP_BIND: {
        bindings_insert(&exc_frame.bindings, op.data.var_id, exc_frame.node);
        exc_frame.pc++;
        break;
      }
      case OP_CALL: {
        exc_frame.pc++;
        CallFrame next_call_frame = {
            .call_mode = op.data.call_parameters.mode,
            .has_continuation = true,
            .continuation = exc_frame,
        };

        ExecutionFrame next_exc_frame = {
            .pc = op.data.call_parameters.relative
                      ? exc_frame.pc + op.data.call_parameters.pc - 1
                      : op.data.call_parameters.pc,
            .node = exc_frame.node,
            .node_stack = NULL};
        bindings_init(&next_exc_frame.bindings);

        ExecutionStack_init(&next_call_frame.exc_stack);
        ExecutionStack_append(&next_call_frame.exc_stack, next_exc_frame);
        CallStack_append(&engine->call_stack, next_call_frame);

        return EXC_CONTINUE;
      }
      case OP_RETURN: {
        exc_frame.pc++;

        *out = exc_frame;
        return EXC_RET;
      }
      case OP_YIELD: {
        bindings_overlay(&match->bindings, &exc_frame.bindings);

        match->node = exc_frame.node;
        return EXC_MATCH;
      }
      case OP_PUSHNODE: {
        exc_frame.pc++;
        exc_frame.node_stack =
            node_stack_push(engine, exc_frame.node_stack, exc_frame.node);
        // printf("%p\n", (void*)exc_frame.node_stack);
      } break;
      case OP_POPNODE: {
        exc_frame.pc++;
        exc_frame.node = node_stack_pop(engine, &exc_frame.node_stack);
      } break;
      }
    } while (!frame_done);
  }

  return EXC_FAIL;
}

bool engine_next_match(Engine *engine, Match *match) {
  CallFrame *call_frame = NULL, *prev_call_frame = NULL;
  bool restore_continuation, pop_call_frame, match_found;
  ExecutionResult result;

  while (engine->call_stack.len > 0) {
    ExecutionFrame out;
    restore_continuation = false;
    pop_call_frame = false;
    match_found = false;

    call_frame = &engine->call_stack.data[engine->call_stack.len - 1];
    prev_call_frame = engine->call_stack.len > 1
                          ? &engine->call_stack.data[engine->call_stack.len - 2]
                          : NULL;

    result = engine_step_execution_frame(engine, &call_frame->exc_stack, match,
                                         &out);
    switch (result) {
    case EXC_FAIL: {
      switch (call_frame->call_mode) {
      case CALLMODE_PASSTHROUGH:
      case CALLMODE_EXISTS:
        pop_call_frame = true;
        break;
      case CALLMODE_NOTEXISTS:
        restore_continuation = true;
        pop_call_frame = true;
        break;
      }
    } break;
    case EXC_MATCH: {
      switch (call_frame->call_mode) {
      case CALLMODE_PASSTHROUGH:
        assert(!ts_node_is_null(match->node));
        restore_continuation = true;
        match_found = true;
        break;
      case CALLMODE_EXISTS:
        restore_continuation = true;
        pop_call_frame = true;
        break;
      case CALLMODE_NOTEXISTS:
        pop_call_frame = true;
        break;
      }
    } break;
    case EXC_RET: {
      if (prev_call_frame != NULL && call_frame->has_continuation) {
        // TODO: Please clean this up.
        out.pc = call_frame->continuation.pc;
        out.node = call_frame->continuation.node;
        for (int i = 0; i < call_frame->continuation.bindings.storage.len;
             i++) {
          Binding binding = call_frame->continuation.bindings.storage.data[i];
          bindings_insert(&out.bindings, binding.variable, binding.value);
        }
        ExecutionStack_append(&prev_call_frame->exc_stack, out);
      }
    } break;
    case EXC_CONTINUE:
      break;
    }

    if (restore_continuation && call_frame->has_continuation &&
        prev_call_frame != NULL) {
      ExecutionStack_append(&prev_call_frame->exc_stack,
                            call_frame->continuation);
    }
    if (pop_call_frame) {
      // FIXME: deinitialize the call frame before going next
      engine->call_stack.len--;
    }

    if (match_found) {
      assert(!ts_node_is_null(match->node));
      return true;
    }
  }

  return false;
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
