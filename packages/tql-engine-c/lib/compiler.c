#include "compiler.h"

void compiler_init(Compiler *compiler) { Ops_init(&compiler->ops); }
void compiler_free(Compiler *compiler) { Ops_free(&compiler->ops); }
void compiler_compile(Compiler *compiler, TQLAst *ast, Ops *out) {}
