#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "engine.h"

struct Compiler;

typedef struct Compiler Compiler;

void compiler_init(Compiler *compiler, TSLanguage *language);
void compiler_compile(Compiler *compiler, TQLAst *ast);
void compiler_free(Compiler *compiler);

#endif /* _COMPILER_H_ */
