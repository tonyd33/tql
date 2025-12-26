#ifndef _ARENA_H_
#define _ARENA_H_

#include <stddef.h>

typedef struct {
  size_t capacity;
  size_t offset;
  char *memory;
} Arena;

Arena *arena_new(size_t capacity);
void *arena_alloc(Arena *arena, size_t size);
void arena_free(Arena *arena);

#endif /* _ARENA_H_ */
