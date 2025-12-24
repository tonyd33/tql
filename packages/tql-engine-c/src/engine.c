#include "engine.h"
#include <stdio.h>

void engine_init(Engine *engine) {
  engine->ast = NULL;
  engine->source = NULL;
  FunctionTable_init(&engine->function_table);
  ExecutionStack_init(&engine->stack);
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
  // IMPROVE: Use arena allocation
  Bindings *root_bindings = malloc(sizeof(Bindings));
  bindings_init(root_bindings);

  NodeStack *root_node_stack = malloc(sizeof(NodeStack));
  NodeStack_init(root_node_stack);

  ExecutionFrame root_frame = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .bindings = root_bindings,
      .node_stack = root_node_stack,
  };
  ExecutionStack_append(&engine->stack, root_frame);
}

bool engine_find_main(Engine *engine, Function *out) {
  for (uint64_t i = 0; i < engine->function_table.len; i++) {
    if (engine->function_table.data[i].id == 0) {
      *out = engine->function_table.data[i];
      return true;
    }
  }
  return false;
}

bool engine_next_match(Engine *engine, Match *match) {
  const TSLanguage *language = ts_tree_language(engine->ast);
  Function main;
  assert(engine_find_main(engine, &main) && "Could not find main");
  while (engine->stack.len > 0) {
    ExecutionFrame frame = engine->stack.data[--engine->stack.len];
    bool frame_done = false;
    bool match_found = false;

    do {
      if (frame.pc >= main.function.len) {
        frame_done = true;
        break;
      }

      Op op = main.function.data[frame.pc];
      switch (op.opcode) {
      case OP_NOOP: {
        frame.pc++;
        break;
      }
      case OP_PUSHNODE: {
        NodeStack_append(frame.node_stack, frame.node);
        frame.pc++;
        break;
      }
      case OP_POPNODE: {
        frame.node = frame.node_stack->data[--frame.node_stack->len];
        frame.pc++;
        break;
      }
      case OP_BRANCH: {
        Axis axis = op.data.axis;
        uint64_t next_pc = frame.pc + 1;
        TSNodes branches;
        TSNodes_init(&branches);

        switch (axis.axis_type) {
        case AXIS_CHILD: {
          for (uint32_t i = 0; i < ts_node_named_child_count(frame.node); i++) {
            TSNodes_append(&branches, ts_node_named_child(frame.node, i));
          }
          break;
        }
        case AXIS_DESCENDANT: {
          TSNodes desc_stack;
          TSNodes_init(&desc_stack);
          TSNodes_append(&desc_stack, frame.node);
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
          for (uint32_t i = 0; i < ts_node_named_child_count(frame.node); i++) {
            const char *field_name_for_named_child =
                ts_node_field_name_for_named_child(frame.node, i);
            if (field_name_for_named_child == NULL ||
                strcmp(field_name_for_named_child, field_name) != 0) {
              continue;
            }
            TSNodes_append(&branches, ts_node_named_child(frame.node, i));
          }
          break;
        }
        default: {
          assert(false && "Unknown axis");
        }
        }

        for (uint32_t i = 0; i < branches.len; i++) {
          TSNode branch = branches.data[i];

          Bindings *overlay = malloc(sizeof(Bindings));
          bindings_overlay(overlay, frame.bindings);
          // IMPROVE: There should be a better way to do this
          NodeStack *node_stack = malloc(sizeof(NodeStack));
          NodeStack_clone(node_stack, frame.node_stack);
          ExecutionFrame frame = {
              .pc = next_pc,
              .node = branch,
              .bindings = overlay,
              .node_stack = node_stack,
          };
          ExecutionStack_append(&engine->stack, frame);
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

          assert(left.node_expression_type == NODEEXPR_SELF && "Only self supported");

          frame_done = ts_node_symbol(frame.node) != right;
          break;
        }
        case PREDICATE_TEXTEQ: {
          NodeExpression left = predicate.data.texteq.node_expression;
          // FIXME: This is dangerous...
          const char *right = predicate.data.texteq.text;

          assert(left.node_expression_type == NODEEXPR_SELF && "Only self supported");

          uint32_t start_byte = ts_node_start_byte(frame.node);
          uint32_t end_byte = ts_node_end_byte(frame.node);
          uint32_t buf_len = end_byte - start_byte;
          char buf[buf_len + 1];

          strncpy(buf, engine->source + start_byte, buf_len);
          buf[buf_len] = '\0';
          frame_done = strncmp(buf, right, buf_len) != 0;
          break;
        }
        default: {
          assert(false && "Unknown predicate type");
          break;
        }
        }

        frame.pc++;
        break;
      }
      case OP_BIND: {
        bindings_insert(frame.bindings, op.data.var_id, frame.node);
        frame.pc++;
        break;
      }
      case OP_CALL: {
        break;
      }
      case OP_YIELD: {
        Bindings *overlay = malloc(sizeof(Bindings));
        bindings_overlay(overlay, frame.bindings);
        *match = (Match){
            .node = frame.node,
            .bindings = overlay,
        };
        match_found = true;
        frame_done = true;
        break;
      }
      default:
        assert(false && "Unknown opcode");
      }
    } while (!frame_done);

    // The overlays may be referenced in other stackframes though...
    // Possibly use a ref count for memory management?
    NodeStack_free(frame.node_stack);
    if (match_found) {
      return true;
    }
  }

  return false;
}

void engine_free(Engine *engine) {
  engine->ast = NULL;
  engine->source = NULL;
  FunctionTable_free(&engine->function_table);
  ExecutionStack_free(&engine->stack);
}
