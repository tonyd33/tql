#include "tree_sitter/parser.h"

#include <stdbool.h>

enum TokenType {
  ATTACHED_MINUS,
  PREFIX_MINUS,
  ERROR_SENTINEL,
};

void *tree_sitter_tql_external_scanner_create(void) { return NULL; }

void tree_sitter_tql_external_scanner_destroy(void *payload) {}

unsigned tree_sitter_tql_external_scanner_serialize(void *payload, char *buffer) { return 0; }

void tree_sitter_tql_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {}

static bool is_space(int32_t c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }

static bool is_digit(int32_t c) { return c >= '0' && c <= '9'; }

static bool starts_operand(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '(' || c == '[';
}

// A `-` directly after an operand is `ATTACHED_MINUS`. A `-` with no operand
// before it, or after whitespace, directly before a name or bracket is
// `PREFIX_MINUS`. Any other `-` is left to the lexer: a spaced operator, a
// negative number or a comment.
bool tree_sitter_tql_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  if (valid_symbols[ERROR_SENTINEL]) return false;

  bool spaced = false;
  while (is_space(lexer->lookahead)) {
    spaced = true;
    lexer->advance(lexer, true);
  }
  if (lexer->lookahead != '-') return false;
  lexer->advance(lexer, false);
  lexer->mark_end(lexer);
  int32_t next = lexer->lookahead;
  if (next == '-') return false;

  if (!spaced && valid_symbols[ATTACHED_MINUS]) {
    lexer->result_symbol = ATTACHED_MINUS;
    return true;
  }
  if (valid_symbols[PREFIX_MINUS] && !is_digit(next) && starts_operand(next)) {
    lexer->result_symbol = PREFIX_MINUS;
    return true;
  }
  return false;
}
