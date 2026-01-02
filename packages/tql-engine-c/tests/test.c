#include "util.h"
#include "test_compiler.c"
#include "test_parser.c"

int main(int argc, char **argv) {
  expect(test_compiler());
  expect(test_parser());

  return 0;
}
