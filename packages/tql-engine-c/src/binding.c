#include "binding.h"
#include <string.h>

void bindings_init(Bindings *bindings) { _Bindings_init(bindings); }
void bindings_free(Bindings *bindings) { _Bindings_free(bindings); }
Bindings *bindings_clone(Bindings *bindings) {
  Bindings *new_bindings = malloc(sizeof(Bindings));
  new_bindings->len = bindings->len;
  new_bindings->cap = bindings->cap;
  new_bindings->data = malloc(sizeof(Binding) * bindings->cap);
  memcpy(new_bindings->data, bindings->data, sizeof(Binding) * bindings->cap);
  return new_bindings;
}

void bindings_insert(Bindings *bindings, VarId variable, TQLValue value) {
  Binding binding = {
      .variable = variable,
      .value = value,
  };
  _Bindings_append(bindings, binding);
}
