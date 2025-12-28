#ifndef _BINDING_H_
#define _BINDING_H_

#include "ds.h"
#include <assert.h>
#include <stdint.h>
#include <tree_sitter/api.h>

typedef uint64_t VarId;

typedef TSNode TQLValue;

typedef struct Binding Binding;
typedef struct Bindings Bindings;

struct Binding {
  VarId variable;
  TQLValue value;
};

struct Bindings {
  Bindings *parent;
  uint16_t ref_count;
  Binding binding;
};

Bindings *bindings_new();
void bindings_free(Bindings *bindings);

TQLValue *bindings_get(Bindings *bindings, VarId variable);
Bindings *bindings_insert(Bindings *bindings, VarId variable, TQLValue value);
void bindings_delete(Bindings *bindings, VarId variable);

#endif /* _BINDING_H_ */
