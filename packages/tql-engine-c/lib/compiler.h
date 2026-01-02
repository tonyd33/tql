#ifndef _COMPILER_H_
#define _COMPILER_H_

#include "ast.h"
#include "vm.h"
#include <tree_sitter/api.h>

typedef uint64_t Symbol;

typedef struct TQLCompiler TQLCompiler;
typedef struct SymbolEntry SymbolEntry;
typedef struct Section Section;

typedef enum SymbolType {
  SYMBOL_VARIABLE,
  SYMBOL_FIELD,
  SYMBOL_FUNCTION,
} SymbolType;

struct SymbolEntry {
  Symbol id;
  SymbolType type;
  StringSlice slice;
  // FIXME: This doesn't belong
  uint32_t placement;
};
DA_DEFINE(SymbolEntry, SymbolTable, symbol_table)

TQLCompiler *tql_compiler_new(TQLAst *ast, SymbolTable *symtab);
void tql_compiler_free(TQLCompiler *compiler);
Program tql_compiler_compile(TQLCompiler *compiler);

#endif /* _COMPILER_H_ */
