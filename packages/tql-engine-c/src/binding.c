#include "binding.h"

void bindings_init(Bindings *bindings) { _Bindings_init(bindings); }
void bindings_free(Bindings *bindings) { _Bindings_free(bindings); }
void bindings_overlay(Bindings *dest, Bindings *src) {
  _Bindings_clone(dest, src);
}

TQLValue *bindings_get(Bindings *bindings, VarId variable) {
    for (size_t i = 0; i < bindings->len; i++) {
        if (variable == bindings->data[i].variable) {
            return &bindings->data[i].value;
        }
    }
    return NULL;
}
void bindings_insert(Bindings *bindings, VarId variable, TQLValue value) {
  Binding binding = {
      .variable = variable,
      .value = value,
  };
  _Bindings_append(bindings, binding);
}

