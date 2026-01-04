#ifndef _CONTEXT_H_
#define _CONTEXT_H_

#include "arena.h"
#include "string_interner.h"

typedef struct TQLContext {
  Arena *arena;
  StringInterner *string_interner;
} TQLContext;

TQLContext *tql_context_new();
void tql_context_free(TQLContext *ctx);

void *tql_context_alloc(TQLContext *ctx, size_t size);
StringSlice tql_context_intern_string(TQLContext *ctx, const char *string,
                                      uint32_t length);

#endif /* _CONTEXT_H_ */
