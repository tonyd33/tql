#include "engine.h"
#include <stdio.h>

void engine_init(Engine *engine) {
  engine->ast = NULL;
  Ops_init(&engine->program);
  Stack_init(&engine->stack);
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
  Bindings first_bindings;
  bindings_init(&first_bindings);
  NodeStack first_node_stack;
  NodeStack_init(&first_node_stack);
  Frame first_frame = {
      .pc = 0,
      .node = ts_tree_root_node(engine->ast),
      .bindings = &first_bindings,
      .node_stack = first_node_stack,
  };
  Stack_append(&engine->stack, first_frame);

  Matches *matches = malloc(sizeof(Matches));
  Matches_init(matches);

  bool done = false;
  do {
    if (engine->stack.len == 0) {
      break;
    }
    Frame frame = engine->stack.data[--engine->stack.len];
    do {
      if (frame.pc >= engine->program.len) {
        break;
      }

      Op op = engine->program.data[frame.pc];
      printf("Opcode: %d, operand: %llu\n", op.opcode, (VarId)op.operand);
      switch (op.opcode) {
      case Noop: {
        frame.pc++;
        break;
      }
      case Push: {
        NodeStack_append(&frame.node_stack, frame.node);
        frame.pc++;
        break;
      }
      case Pop: {
        frame.node = frame.node_stack.data[--frame.node_stack.len];
        frame.pc++;
        break;
      }
      case Transition: {
        assert(false && "Not Implemented");
        break;
      }
      case Bind: {
        bindings_insert(frame.bindings, (VarId)op.operand, frame.node);
        frame.pc++;
        break;
      }
      case Yield: {
        Match match = {
            .node = frame.node,
            .bindings = bindings_clone(frame.bindings),
        };
        Matches_append(matches, match);
        done = true;
        break;
      }
      default:
        assert(false && "Unknown opcode");
      }
    } while (!done);
  } while (!done);

  return matches;
}
