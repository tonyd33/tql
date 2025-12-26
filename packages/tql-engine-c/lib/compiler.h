#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "engine.h"

typedef struct {
} Compiler;

void compiler_init(Compiler *compiler);
void compiler_compile(Compiler *compiler, TqlAst *ast, Ops *out);
void compiler_free(Compiler *compiler);

#endif /* _COMPILER_H_ */
