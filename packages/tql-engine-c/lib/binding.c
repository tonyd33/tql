#include "binding.h"

void bindings_free(Bindings *bindings) {
  if (bindings == NULL || bindings->ref_count == 0) {
    return;
  }
  bindings->ref_count--;
  if (bindings->ref_count == 0) {
    if (bindings->parent != NULL) {
      bindings_free(bindings->parent);
    }
    bindings->parent = NULL;
  }
}

TQLValue *bindings_get(Bindings *bindings, VarId variable) {
  while (bindings != NULL) {
    if (bindings->binding.variable == variable) {
      return &bindings->binding.value;
    }
    bindings = bindings->parent;
  }
  return NULL;
}

Bindings *bindings_insert(Bindings *bindings, VarId variable, TQLValue value) {
  Bindings *overlay = malloc(sizeof(Bindings));
  overlay->parent = bindings;
  overlay->binding = (Binding){
      .variable = variable,
      .value = value,
  };
  if (bindings != NULL) {
    bindings->ref_count++;
  }
  return overlay;
}
