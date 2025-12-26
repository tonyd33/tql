#include "arena.h"
#include <stdint.h>
#include <stdlib.h>

Arena *arena_new(size_t capacity) {
  Arena *arena = malloc(sizeof(Arena));
  arena->memory = malloc(capacity);
  arena->capacity = capacity;
  arena->offset = 0;
  return arena;
}

void *arena_alloc(Arena *arena, size_t size) {
  if (arena->offset + size > arena->capacity) {
    return NULL;
  }
  uintptr_t memory = (uintptr_t)(arena->memory) + arena->offset;
  arena->offset += size;
  return (void*)memory;
}

void arena_free(Arena *arena) {
  arena->offset = 0;
  arena->capacity = 0;
  free(arena->memory);
  arena->memory = NULL;
  free(arena);
}
