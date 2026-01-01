#ifndef _PARSER_H_
#define _PARSER_H_

#include "ast.h"
#include <tree_sitter/api.h>

struct TQLParser;

typedef struct TQLParser TQLParser;

TQLParser *tql_parser_new();
TQLAst *tql_parser_parse_string(TQLParser *parser, const char *string,
                                uint32_t length);
void tql_parser_free(TQLParser *parser);

#endif /* _PARSER_H_ */
