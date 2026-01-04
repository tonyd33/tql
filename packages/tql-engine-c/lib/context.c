#include "context.h"

TQLContext *tql_context_new() {
  TQLContext *ctx = malloc(sizeof(TQLContext));
  ctx->arena = arena_new(32768);
  ctx->string_interner = string_interner_new(32768);

  return ctx;
}
void tql_context_free(TQLContext *ctx) {
  string_interner_free(ctx->string_interner);
  ctx->string_interner = NULL;
  arena_free(ctx->arena);
  ctx->arena = NULL;
  free(ctx);
}

void *tql_context_alloc(TQLContext *ctx, size_t size) {
  return arena_alloc(ctx->arena, size);
}

StringSlice tql_context_intern_string(TQLContext *ctx, const char *string,
                                      uint32_t length) {
  return string_interner_intern(ctx->string_interner, string, length);
}
