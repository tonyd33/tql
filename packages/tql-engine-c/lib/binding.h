#ifndef _BINDING_H_
#define _BINDING_H_

#include "ds.h"
#include <assert.h>
#include <stdint.h>
#include <tree_sitter/api.h>

typedef uint64_t VarId;

typedef TSNode TQLValue;

typedef struct {
  VarId variable;
  TQLValue value;
} Binding;

DA_DEFINE(Binding, _Bindings)

typedef _Bindings Bindings;

/*
 * The idea is that, to be more memory-efficient in the future, overlay
 * operations will create an "overlay" of the previous bindings, such that
 * lookups on the new bindings will search in the overlay first, and have the
 * ability to fall back to the previous binding.
 *
 * This effectively implements a memory-efficient scoped lookup table.
 */

void bindings_init(Bindings *bindings);
void bindings_free(Bindings *bindings);
void bindings_overlay(Bindings *dest, Bindings *src);

TQLValue *bindings_get(Bindings *bindings, VarId variable);
void bindings_insert(Bindings *bindings, VarId variable, TQLValue value);
void bindings_delete(Bindings *bindings, VarId variable);

#endif /* _BINDING_H_ */
