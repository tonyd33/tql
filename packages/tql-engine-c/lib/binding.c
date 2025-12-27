#include "binding.h"

void bindings_init(Bindings *bindings) {
  bindings->parent = NULL;
  bindings->ref_count = 1;
  BindingsArray_init(&bindings->storage);
}

void bindings_free(Bindings *bindings) {
  if (bindings->ref_count == 0) {
    return;
  }
  bindings->ref_count--;
  // if (bindings->ref_count == 0) {
  //   BindingsArray_free(&bindings->storage);
  //   if (bindings->parent != NULL) {
  //     bindings_free(bindings->parent);
  //   }
  //   bindings->parent = NULL;
  // }
}

void bindings_overlay(Bindings *dest, Bindings *src) {
  dest->parent = src;
  dest->ref_count = 1;
  src->ref_count++;
  BindingsArray_clone(&dest->storage, &src->storage);
  // BindingsArray_init(&dest->storage);
}

TQLValue *bindings_get(Bindings *bindings, VarId variable) {
  for (size_t i = 0; i < bindings->storage.len; i++) {
    if (variable == bindings->storage.data[i].variable) {
      return &bindings->storage.data[i].value;
    }
  }
  return NULL;
  // if (bindings->parent != NULL) {
  //   return bindings_get(bindings->parent, variable);
  // } else {
  //   return NULL;
  // }
}
void bindings_insert(Bindings *bindings, VarId variable, TQLValue value) {
  Binding binding = {
      .variable = variable,
      .value = value,
  };
  BindingsArray_append(&bindings->storage, binding);
}
