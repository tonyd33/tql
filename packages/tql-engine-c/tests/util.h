#ifndef _UTIL_H_
#define _UTIL_H_
#include "lib/ds.h"
#include <tree_sitter/api.h>

#define expect(condition)                                                      \
  {                                                                            \
    if (!(condition)) {                                                        \
      printf("Failed condition at %s:%d\n", __FILE__, __LINE__);               \
      return false;                                                            \
    }                                                                          \
  }

static inline String read_file(const char *filename) {
  String s;
  FILE *fp = fopen(filename, "r");
  if (fp == NULL) {
    perror("fopen");
    assert(false);
  }

  fseek(fp, 0, SEEK_END);
  uint32_t length = ftell(fp);
  fseek(fp, 0, SEEK_SET);

  string_init(&s);
  string_reserve(&s, length);
  s.len = length;
  assert(fread(s.data, 1, length, fp) == length);
  fclose(fp);
  return s;
}

static inline String get_ts_node_text(const String source, TSNode node) {
  String s;
  string_init(&s);
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  uint32_t buf_len = end_byte - start_byte;

  string_reserve(&s, buf_len);
  s.len = buf_len;
  strncpy(s.data, source.data + start_byte, buf_len);
  return s;
}
#endif /* _UTIL_H_ */
