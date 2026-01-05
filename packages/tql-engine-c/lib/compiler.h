#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "vm.h"
#include <tree_sitter/api.h>

typedef struct TQLCompiler TQLCompiler;
typedef struct Section Section;

TQLCompiler *tql_compiler_new(TQLAst *ast);
void tql_compiler_free(TQLCompiler *compiler);
TQLProgram *tql_compiler_compile(TQLCompiler *compiler);

#endif /* _COMPILER_H_ */
