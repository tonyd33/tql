#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "engine.h"

typedef struct {
  Ops ops;
  TSLanguage *language;
} Compiler;

void compiler_init(Compiler *compiler, TSLanguage *language);
void compiler_compile(Compiler *compiler, TQLAst *ast, Ops *out);
void compiler_free(Compiler *compiler);

#endif /* _COMPILER_H_ */
