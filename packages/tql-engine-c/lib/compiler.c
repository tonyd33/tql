#include "compiler.h"

void compiler_init(Compiler *compiler, TSLanguage *language) {
  Ops_init(&compiler->ops);
  compiler->language = language;
}
void compiler_free(Compiler *compiler) { Ops_free(&compiler->ops); }

// static void compile_tql_selector(Compiler *compiler, TQLSelector *selector) {
//   switch (selector->type) {
//   case TQLSELECTOR_SELF:
//   case TQLSELECTOR_UNIVERSAL:
//   case TQLSELECTOR_NODETYPE:
//     Ops_append(
//         &compiler->ops,
//         op_if(predicate_typeeq(
//             node_expression_self(),
//             ts_language_field_id_for_name(
//                 compiler->language, selector->data.node_type_selector->string,
//                 selector->data.node_type_selector->length))));
//     break;
//   case TQLSELECTOR_FIELDNAME:
//   case TQLSELECTOR_CHILD:
//   case TQLSELECTOR_DESCENDANT:
//   case TQLSELECTOR_BLOCK:
//   case TQLSELECTOR_VARID:
//     break;
//   }
// }
// static void compile_tql_tree(Compiler *compiler, TQLTree *tree) {}

void compiler_compile(Compiler *compiler, TQLAst *ast, Ops *out) {}
