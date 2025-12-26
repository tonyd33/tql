#ifndef _DS_H_
#define _DS_H_

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

static inline size_t dyn_array_next_cap(size_t cap) {
  return cap ? cap * 2 : 1;
}

#define DA_DEFINE(T, Name)                                                     \
  typedef struct {                                                             \
    size_t len;                                                                \
    size_t cap;                                                                \
    T *data;                                                                   \
  } Name;                                                                      \
                                                                               \
  static inline void Name##_init(Name *a) {                                    \
    a->data = NULL;                                                            \
    a->len = 0;                                                                \
    a->cap = 0;                                                                \
  }                                                                            \
                                                                               \
  static inline void Name##_free(Name *a) {                                    \
    free(a->data);                                                             \
    a->data = NULL;                                                            \
    a->len = 0;                                                                \
    a->cap = 0;                                                                \
  }                                                                            \
                                                                               \
  static inline bool Name##_reserve(Name *a, size_t new_cap) {                 \
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
  static inline bool Name##_append(Name *a, T value) {                         \
    if (a->len == a->cap) {                                                    \
      size_t new_cap = dyn_array_next_cap(a->cap);                             \
      if (!Name##_reserve(a, new_cap))                                         \
        return false;                                                          \
    }                                                                          \
                                                                               \
    a->data[a->len++] = value;                                                 \
    return true;                                                               \
  }                                                                            \
                                                                               \
  static inline void Name##_clone(Name *dest, Name *src) {                     \
    Name##_init(dest);                                                         \
    dest->len = src->len;                                                      \
    dest->cap = src->cap;                                                      \
    dest->data = (T *)malloc(sizeof(T) * src->cap);                            \
    memcpy(dest->data, src->data, sizeof(T) * src->cap);                       \
  }                                                                            \
                                                                               \
  static inline const T *Name##_get(const Name *a, size_t i) {                 \
    assert(i < a->len);                                                        \
    return &a->data[i];                                                        \
  }

#endif /* _DS_H_ */
