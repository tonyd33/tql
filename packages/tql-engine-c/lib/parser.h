#ifndef _PARSER_H_
#define _PARSER_H_

#include <tree_sitter/api.h>
#include "ast.h"

typedef struct {
  TSParser *ts_parser;
} TQLParser;

void tql_parser_init(TQLParser *parser);
TQLAst *tql_parser_parse_string(TQLParser *parser, const char *string, uint32_t length);
void tql_parser_free(TQLParser *parser);

#endif /* _PARSER_H_ */
