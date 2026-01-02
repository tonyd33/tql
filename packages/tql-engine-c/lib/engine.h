#ifndef _ENGINE_H_
#define _ENGINE_H_

#include "arena.h"
#include "ds.h"
#include "vm.h"
#include <tree_sitter/api.h>

struct Engine;

typedef struct Engine Engine;

Engine *engine_new();
void engine_free(Engine *engine);

void engine_compile_query(Engine *engine, const char *buf, uint32_t length);
void engine_load_target_string(Engine *engine, const char *buf,
                               uint32_t length);
void engine_exec(Engine *engine);
bool engine_next_match(Engine *engine, Match *match);

const VmStats *engine_get_vm_stats(const Engine *engine);

#endif /* _ENGINE_H_ */
