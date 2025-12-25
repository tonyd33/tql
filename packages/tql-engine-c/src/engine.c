#include "engine.h"
#include <stdio.h>

static const FunctionId MAIN_ID = 0;

typedef enum {
  /* An execution stack has been exhausted and nothing was found. */
  EXC_FAIL,
  /* A match was found while executing an execution stack.
   * There may be more matches. */
  EXC_MATCH,
  /* There may or may not be a match in this execution stack. We must continue
   * evaluating a new execution stack to determine. */
  EXC_CONTINUE,
} ExecutionResult;

void engine_init(Engine *engine) {
  engine->ast = NULL;
  engine->source = NULL;
  FunctionTable_init(&engine->function_table);
  CallStack_init(&engine->call_stack);
}

void engine_free(Engine *engine) {
  CallStack_free(&engine->call_stack);
  FunctionTable_free(&engine->function_table);
  engine->source = NULL;
  engine->ast = NULL;
}

void engine_load_ast(Engine *engine, TSTree *ast) { engine->ast = ast; }

void engine_load_source(Engine *engine, const char *source) {
  engine->source = source;
}

void engine_load_function(Engine *engine, Function *function) {
  // FIXME: We need to copy over the Ops so it's owned by the engine.
  FunctionTable_append(&engine->function_table, *function);
}

void engine_exec(Engine *engine) {
  CallFrame root_call_frame = {
      .call_mode = CALLMODE_JOIN,
      .has_continuation = false,
  };

  ExecutionFrame root_exc_frame = {
      .function_id = MAIN_ID,
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
  };
  bindings_init(&root_exc_frame.bindings);
  NodeStack_init(&root_exc_frame.node_stack);

  ExecutionStack_init(&root_call_frame.exc_stack);
  ExecutionStack_append(&root_call_frame.exc_stack, root_exc_frame);
  CallStack_append(&engine->call_stack, root_call_frame);
}

static bool engine_find_function(Engine *engine, FunctionId id, Function *out) {
  for (uint64_t i = 0; i < engine->function_table.len; i++) {
    if (engine->function_table.data[i].id == id) {
      *out = engine->function_table.data[i];
      return true;
    }
  }
  return false;
}

static bool engine_find_main(Engine *engine, Function *out) {
  return engine_find_function(engine, MAIN_ID, out);
}

/*
 * Termination of this function means either:
 * - EXC_MATCH: We found a result, and it has been stored in match. The current
 * execution stack may be resumed to find more results.
 * - EXC_FAIL: All execution frames in the stack were exhausted without any
 * results.
 * - EXC_CONTINUE: We must continue in a separate execution frame.
 */
static ExecutionResult engine_step_execution_frame(Engine *engine,
                                                   ExecutionStack *exc_stack,
                                                   Match *match) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  while (exc_stack->len > 0) {
    ExecutionFrame exc_frame = exc_stack->data[--exc_stack->len];
    Function curr_function;
    assert(
        engine_find_function(engine, exc_frame.function_id, &curr_function) &&
        "Could not find function");
    bool frame_done = false;

    do {
      if (exc_frame.pc >= curr_function.function.len) {
        frame_done = true;
        break;
      }

      Op op = curr_function.function.data[exc_frame.pc];
      // printf("function id %llu, opcode %d\n", curr_function.id, op.opcode);
      switch (op.opcode) {
      case OP_NOOP: {
        exc_frame.pc++;
        break;
      }
      case OP_PUSHNODE: {
        NodeStack_append(&exc_frame.node_stack, exc_frame.node);
        exc_frame.pc++;
        break;
      }
      case OP_POPNODE: {
        exc_frame.node = exc_frame.node_stack.data[--exc_frame.node_stack.len];
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
          for (uint32_t i = 0; i < ts_node_named_child_count(exc_frame.node);
               i++) {
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
            for (uint32_t i = 0; i < ts_node_named_child_count(curr); i++) {
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
          for (uint32_t i = 0; i < ts_node_named_child_count(exc_frame.node);
               i++) {
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
          NodeStack node_stack;
          NodeStack_clone(&node_stack, &exc_frame.node_stack);
          ExecutionFrame frame = {
              .function_id = exc_frame.function_id,
              .pc = next_pc,
              .node = branch,
              .bindings = overlay,
              .node_stack = node_stack,
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
            .function_id = op.data.call_parameters.function_id,
            .pc = 0,
            .node = exc_frame.node};
        bindings_init(&next_exc_frame.bindings);
        NodeStack_init(&next_exc_frame.node_stack);

        ExecutionStack_init(&next_call_frame.exc_stack);
        ExecutionStack_append(&next_call_frame.exc_stack, next_exc_frame);
        CallStack_append(&engine->call_stack, next_call_frame);

        // NodeStack_free(&exc_frame.node_stack);
        return EXC_CONTINUE;
      }
      case OP_RETURN: {
        frame_done = true;
        break;
      }
      case OP_YIELD: {
        match->node = exc_frame.node;
        bindings_overlay(&match->bindings, &exc_frame.bindings);
        NodeStack_free(&exc_frame.node_stack);

        return EXC_MATCH;
      }
      default:
        assert(false && "Unknown opcode");
      }
    } while (!frame_done);

    // The overlays may be referenced in other stackframes though...
    // Possibly use a ref count for memory management?
    // Ideally, a node stack wouldn't be stored in here as well...
    NodeStack_free(&exc_frame.node_stack);
  }

  return EXC_FAIL;
}

bool engine_next_match(Engine *engine, Match *match) {
  CallFrame *call_frame = NULL, *prev_call_frame = NULL;
  bool restore_continuation, pop_call_frame, match_found;
  ExecutionResult result;

  while (engine->call_stack.len > 0) {
    restore_continuation = false, pop_call_frame = false, match_found = false;

    call_frame = &engine->call_stack.data[engine->call_stack.len - 1];
    prev_call_frame = engine->call_stack.len > 1
                          ? &engine->call_stack.data[engine->call_stack.len - 2]
                          : NULL;

    result = engine_step_execution_frame(engine, &call_frame->exc_stack, match);
    switch (result) {
    case EXC_FAIL: {
      switch (call_frame->call_mode) {
      case CALLMODE_JOIN:
      case CALLMODE_EXISTS:
        pop_call_frame = true;
        break;
      case CALLMODE_NOTEXISTS:
        restore_continuation = true;
        pop_call_frame = true;
        break;
      }
    }
    case EXC_MATCH: {
      switch (call_frame->call_mode) {
      case CALLMODE_JOIN:
        restore_continuation = true;
        match_found = true;
        break;
      case CALLMODE_EXISTS: {
        restore_continuation = true;
        pop_call_frame = true;
        break;
      }
      case CALLMODE_NOTEXISTS:
        pop_call_frame = true;
        break;
      }
    }
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
      return true;
    }
  }

  return false;
}
