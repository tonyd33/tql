#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "ds.h"
#include "vm.h"
#include <tree_sitter/api.h>

struct Engine;

typedef struct Engine Engine;

Engine *engine_new();
void engine_load_program(Engine *engine, Op *ops, uint32_t op_count);

bool engine_next_match(Engine *engine, Match *match);

void engine_free(Engine *engine);

#endif /* _ENGINE_H_ */
