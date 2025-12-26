#ifndef _AST_H_
#define _AST_H_

typedef struct {
} TqlAst;

TqlAst *tql_ast_parse_from_ts_ast(TSTree *tree);
void tql_ast_free(TqlAst *ast);

#endif /* _AST_H_ */
