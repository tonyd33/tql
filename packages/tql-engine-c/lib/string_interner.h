#ifndef _STRING_INTERNER_H_
#define _STRING_INTERNER_H_

#include "ds.h"

typedef struct {
  StringSlices slices;
  uint32_t pool_capacity;
  char *pool;
} StringInterner;

static inline StringInterner *string_interner_new(uint32_t cap) {
  StringInterner *string_interner =
      (StringInterner *)malloc(sizeof(StringInterner));
  string_slices_init(&string_interner->slices);

  string_interner->pool_capacity = cap;
  string_interner->pool = (char *)malloc(cap);
  return string_interner;
}

static inline void string_interner_free(StringInterner *string_interner) {
  string_slices_deinit(&string_interner->slices);
  free(string_interner->pool);
  string_interner->pool = NULL;
  string_interner->pool_capacity = 0;
  free(string_interner);
}

static inline StringSlice
string_interner_intern(StringInterner *string_interner, const char *string,
                       uint32_t length) {
  char *s = string_interner->pool;
  for (size_t i = 0; i < string_interner->slices.len; i++) {
    StringSlice slice = string_interner->slices.data[i];
    if (slice.len == length && strncmp(s, string, length) == 0) {
      return slice;
    }
    s += slice.len + 1;
    // FIXME: We can allocate more fixed memory regions
    assert(s - string_interner->pool < string_interner->pool_capacity);
  }

  strncpy(s, string, length);
  // not necessary to terminate slices since lengths are well-known, but it's
  // relatively cheap and useful if we don't have access to slice data anymore.
  s[length] = '\0';

  StringSlice slice = {
      .data = s,
      .len = length,
  };
  string_slices_append(&string_interner->slices, slice);
  return slice;
}

#endif /* _STRING_INTERNER_H_ */
