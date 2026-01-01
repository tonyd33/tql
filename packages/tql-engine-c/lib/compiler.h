#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "vm.h"
#include <tree_sitter/api.h>

struct Compiler;

typedef struct Compiler Compiler;

Compiler *compiler_new(TQLAst *ast);
void compiler_free(Compiler *compiler);
Program tql_compiler_compile(Compiler *compiler);
// FIXME: Do not expose this
const TSLanguage *tql_compiler_target(Compiler *compiler);

#endif /* _COMPILER_H_ */
