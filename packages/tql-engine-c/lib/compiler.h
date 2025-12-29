#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "assembler.h"
#include "ast.h"
#include "program.h"

struct Compiler;
struct SymbolEntry;

typedef struct Compiler Compiler;
typedef struct SymbolEntry SymbolEntry;

typedef enum SymbolType {
  SYMBOL_VARIABLE,
  SYMBOL_FUNCTION,
} SymbolType;

struct SymbolEntry {
  SymbolId id;
  SymbolType type;
  union {
    const char *string;
  } data;
};
DA_DEFINE(SymbolEntry, SymbolTable)

struct Compiler {
  Assembler asmb;
  SymbolId next_symbol_id;
  SymbolTable symbol_table;
};

void compiler_init(Compiler *compiler, const TSLanguage *language);
void compiler_compile(Compiler *compiler, TQLAst *ast);
void compiler_free(Compiler *compiler);
Op *compile_tql_tree(Compiler *compiler, const TQLTree *tree,
                     uint32_t *op_count);

#endif /* _COMPILER_H_ */
