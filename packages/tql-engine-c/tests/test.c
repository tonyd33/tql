#include "test_compiler.c"
#include "test_parser.c"
#include "test_query.c"
#include "util.h"

int main(int argc, char **argv) {
  if (!test_compiler())
    return 1;
  if (!test_parser())
    return 1;
  if (!test_query())
    return 1;

  return 0;
}
