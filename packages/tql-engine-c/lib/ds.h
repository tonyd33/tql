#ifndef _DS_H_
#define _DS_H_

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline size_t dyn_array_next_cap(size_t cap) {
  return cap ? cap * 2 : 1;
}

#define DA_DEFINE(T, Name, Prefix)                                             \
  typedef struct {                                                             \
    size_t len;                                                                \
    size_t cap;                                                                \
    T *data;                                                                   \
  } Name;                                                                      \
                                                                               \
  static inline void Prefix##_init(Name *a) {                                  \
    a->data = NULL;                                                            \
    a->len = 0;                                                                \
    a->cap = 0;                                                                \
  }                                                                            \
                                                                               \
  static inline Name *Prefix##_new(void) {                                     \
    Name *a = (Name *)malloc(sizeof(Name));                                    \
    Prefix##_init(a);                                                          \
    return a;                                                                  \
  }                                                                            \
                                                                               \
  static inline void Prefix##_deinit(Name *a) {                                \
    free(a->data);                                                             \
    a->data = NULL;                                                            \
    a->len = 0;                                                                \
    a->cap = 0;                                                                \
  }                                                                            \
                                                                               \
  static inline void Prefix##_free(Name *a) {                                  \
    Prefix##_deinit(a);                                                        \
    free(a);                                                                   \
  }                                                                            \
                                                                               \
  static inline bool Prefix##_reserve(Name *a, size_t new_cap) {               \
    if (new_cap <= a->cap)                                                     \
      return true;                                                             \
                                                                               \
    T *p = (T *)realloc(a->data, new_cap * sizeof(T));                         \
    if (!p)                                                                    \
      return false;                                                            \
                                                                               \
    a->data = p;                                                               \
    a->cap = new_cap;                                                          \
    return true;                                                               \
  }                                                                            \
                                                                               \
  static inline bool Prefix##_append(Name *a, T value) {                       \
    if (a->len == a->cap) {                                                    \
      size_t new_cap = dyn_array_next_cap(a->cap);                             \
      if (!Prefix##_reserve(a, new_cap))                                       \
        return false;                                                          \
    }                                                                          \
                                                                               \
    a->data[a->len++] = value;                                                 \
    return true;                                                               \
  }                                                                            \
                                                                               \
  static inline void Prefix##_clone(Name *dest, Name *src) {                   \
    Prefix##_init(dest);                                                       \
    dest->len = src->len;                                                      \
    dest->cap = src->cap;                                                      \
    dest->data = (T *)malloc(sizeof(T) * src->cap);                            \
    memcpy(dest->data, src->data, sizeof(T) * src->cap);                       \
  }

#define LL_DEFINE(T, Name)                                                     \
  typedef struct Name Name;                                                    \
  struct Name {                                                                \
    Name *next;                                                                \
    T data;                                                                    \
  };                                                                           \
                                                                               \
  static inline Name *Name##_new(T data) {                                     \
    Name *a = (Name *)malloc(sizeof(Name));                                    \
    a->next = NULL;                                                            \
    a->data = data;                                                            \
    return a;                                                                  \
  }                                                                            \
                                                                               \
  static inline void Name##_free(Name *a) {                                    \
    Name *prev;                                                                \
    while (a != NULL) {                                                        \
      prev = a;                                                                \
      a = a->next;                                                             \
      free(a);                                                                 \
    }                                                                          \
  }

DA_DEFINE(char, String, string)
static inline void string_concat(String *a, String b) {
  string_reserve(a, a->len + b.len);
  strncpy(a->data + a->len, b.data, b.len);
  a->len += b.len;
}
static inline String string_from(char *string) {
  return (String){
      .len = (uint32_t)strlen(string),
      .cap = 0,
      .data = string,
  };
}
typedef struct {
  const char *buf;
  uint32_t length;
} StringSlice;
DA_DEFINE(StringSlice, StringSlices, string_slices)

static inline bool string_slice_eq(StringSlice a, StringSlice b) {
  return a.length == b.length && strncmp(a.buf, b.buf, a.length) == 0;
}

static inline StringSlice string_slice_from(char *string) {
  return (StringSlice){
      .buf = string,
      .length = (uint32_t)strlen(string),
  };
}

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

static inline StringSlice string_intern(StringInterner *string_interner,
                                        const char *string, uint32_t length) {
  char *s = string_interner->pool;
  for (size_t i = 0; i < string_interner->slices.len; i++) {
    StringSlice slice = string_interner->slices.data[i];
    if (slice.length == length && strncmp(s, string, length) == 0) {
      return slice;
    }
    s += slice.length + 1;
    // FIXME: We can allocate more fixed memory regions
    assert(s - string_interner->pool < string_interner->pool_capacity);
  }

  strncpy(s, string, length);
  // not necessary to terminate slices since lengths are well-known, but it's
  // relatively cheap and useful if we don't have access to slice data anymore.
  s[length] = '\0';

  StringSlice slice = {
      .buf = s,
      .length = length,
  };
  string_slices_append(&string_interner->slices, slice);
  return slice;
}
#endif /* _DS_H_ */
