#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "vm.h"
#include <tree_sitter/api.h>

struct TQLCompiler;

typedef struct TQLCompiler TQLCompiler;

TQLCompiler *tql_compiler_new(TQLAst *ast);
void tql_compiler_free(TQLCompiler *compiler);
Program tql_compiler_compile(TQLCompiler *compiler);
// FIXME: Do not expose this
const TSLanguage *tql_compiler_target(TQLCompiler *compiler);

#endif /* _COMPILER_H_ */
