#include "engine.h"
#include <stdio.h>

void engine_init(Engine *engine) {
  engine->ast = NULL;
  Ops_init(&engine->program);
}

void engine_load_ast(Engine *engine, TSTree *ast) { engine->ast = ast; }

void engine_load_program(Engine *engine, Ops *program) {
  Ops_reserve(&engine->program, program->cap);
  engine->program.len = program->len;
  for (int i = 0; i < program->cap; i++) {
    engine->program.data[i] = program->data[i];
  }
}

Matches *engine_run(Engine *engine) {
  // IMPROVE: Use arena allocation
  Bindings *root_bindings = malloc(sizeof(Bindings));
  bindings_init(root_bindings);

  NodeStack *root_node_stack = malloc(sizeof(NodeStack));
  NodeStack_init(root_node_stack);

  Frame root_frame = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .bindings = root_bindings,
      .node_stack = root_node_stack,
  };
  Stack stack;
  Stack_init(&stack);
  Stack_append(&stack, root_frame);

  Matches *matches = malloc(sizeof(Matches));
  Matches_init(matches);

  const TSLanguage *language = ts_tree_language(engine->ast);
  while (stack.len > 0) {
    Frame frame = stack.data[--stack.len];
    bool frame_done = false;
    do {
      if (frame.pc >= engine->program.len) {
        frame_done = true;
        break;
      }

      Op op = engine->program.data[frame.pc];
      switch (op.opcode) {
      case Noop: {
        frame.pc++;
        break;
      }
      case PushNode: {
        NodeStack_append(frame.node_stack, frame.node);
        frame.pc++;
        break;
      }
      case PopNode: {
        frame.node = frame.node_stack->data[--frame.node_stack->len];
        frame.pc++;
        break;
      }
      case Branch: {
        Axis *axis = (Axis *)op.operand;
        uint64_t next_pc = frame.pc + 1;
        TSNodes branches;
        TSNodes_init(&branches);

        switch (axis->axis_type) {
        case Child: {
          for (uint32_t i = 0; i < ts_node_named_child_count(frame.node); i++) {
            TSNodes_append(&branches, ts_node_named_child(frame.node, i));
          }
          break;
        }
        case Descendant: {
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
        case Field: {
          TSFieldId field_id = (TSFieldId)axis->operand;
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
          Frame frame = {
              .pc = next_pc,
              .node = branch,
              .bindings = overlay,
              .node_stack = node_stack,
          };
          Stack_append(&stack, frame);
        }

        frame_done = true;
        TSNodes_free(&branches);
        break;
      }
      case If: {
        assert(false && "Not Implemented");
        break;
      }
      case Bind: {
        bindings_insert(frame.bindings, (VarId)op.operand, frame.node);
        frame.pc++;
        break;
      }
      case Yield: {
        Bindings *overlay = malloc(sizeof(Bindings));
        bindings_overlay(overlay, frame.bindings);
        Match match = {
            .node = frame.node,
            .bindings = overlay,
        };
        Matches_append(matches, match);
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
  }

  Stack_free(&stack);
  return matches;
}

void engine_free(Engine *engine) {
  engine->ast = NULL;
  Ops_free(&engine->program);
}
