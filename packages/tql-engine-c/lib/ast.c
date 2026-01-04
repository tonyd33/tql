#include "ast.h"
#include <string.h>

#define AST_ARENA_SIZE 32768

TQLString *tql_string(TQLAst *ast, const char *string, uint32_t length) {
  TQLString *tql_string = tql_context_alloc(ast->ctx, sizeof(TQLString));
  *tql_string = tql_context_intern_string(ast->ctx, string, length);
  tql_string->length = length;
  return tql_string;
}

TQLStatement *tql_statement_selector(TQLAst *ast, TQLSelector *selector) {
  TQLStatement *statement = tql_context_alloc(ast->ctx, sizeof(TQLStatement));
  *statement = (TQLStatement){
      .type = TQLSTATEMENT_SELECTOR,
      .data = {.selector = selector},
  };
  return statement;
}
TQLStatement *tql_statement_assignment(TQLAst *ast, TQLAssignment *assignment) {
  TQLStatement *statement = tql_context_alloc(ast->ctx, sizeof(TQLStatement));
  *statement = (TQLStatement){
      .type = TQLSTATEMENT_ASSIGNMENT,
      .data = {.assignment = assignment},
  };
  return statement;
}

TQLAssignment *tql_assignment(TQLAst *ast,
                              TQLVariableIdentifier *variable_identifier,
                              TQLExpression *expression) {
  TQLAssignment *assignment =
      tql_context_alloc(ast->ctx, sizeof(TQLAssignment));
  *assignment = (TQLAssignment){
      .variable_identifier = variable_identifier,
      .expression = expression,
  };
  return assignment;
}

TQLExpression *tql_expression_selector(TQLAst *ast, TQLSelector *selector) {
  TQLExpression *expression =
      tql_context_alloc(ast->ctx, sizeof(TQLExpression));
  *expression = (TQLExpression){.type = TQLEXPRESSION_SELECTOR,
                                .data = {.selector = selector}};
  return expression;
}

TQLExpression *tql_expression_string(TQLAst *ast, TQLString *string) {
  TQLExpression *expression =
      tql_context_alloc(ast->ctx, sizeof(TQLExpression));
  *expression =
      (TQLExpression){.type = TQLEXPRESSION_STRING, .data = {.string = string}};
  return expression;
}

TQLSelector *tql_selector_self(TQLAst *ast) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_SELF,
  };
  return selector;
}

TQLSelector *tql_selector_nodetype(TQLAst *ast,
                                   TQLVariableIdentifier *node_type) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_NODETYPE,
      .data =
          {
              .node_type_selector = node_type,
          },
  };
  return selector;
}

TQLSelector *tql_selector_fieldname(TQLAst *ast, TQLSelector *parent,
                                    TQLString *field) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_FIELDNAME,
      .data =
          {
              .field_name_selector =
                  {
                      .parent = parent,
                      .field = field,
                  },
          },
  };
  return selector;
}

TQLSelector *tql_selector_child(TQLAst *ast, TQLSelector *parent,
                                TQLSelector *child) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_CHILD,
      .data =
          {
              .child_selector =
                  {
                      .parent = parent,
                      .child = child,
                  },
          },
  };
  return selector;
}

TQLSelector *tql_selector_descendant(TQLAst *ast, TQLSelector *parent,
                                     TQLSelector *child) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_DESCENDANT,
      .data =
          {
              .descendant_selector =
                  {
                      .parent = parent,
                      .child = child,
                  },
          },
  };
  return selector;
}
TQLSelector *tql_selector_block(TQLAst *ast, TQLSelector *parent,
                                TQLStatement **statements,
                                uint32_t statement_count) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  selector->type = TQLSELECTOR_BLOCK;
  selector->data.block_selector.parent = parent;
  if (statement_count > 0) {
    selector->data.block_selector.statements =
        tql_context_alloc(ast->ctx, sizeof(TQLStatement *) * statement_count);
    memcpy(selector->data.block_selector.statements, statements,
           sizeof(TQLStatement *) * statement_count);
    selector->data.block_selector.statement_count = statement_count;
  } else {
    selector->data.block_selector.statements = NULL;
    selector->data.block_selector.statement_count = 0;
  }
  return selector;
}

TQLSelector *tql_selector_varid(TQLAst *ast,
                                TQLVariableIdentifier *identifier) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector =
      (TQLSelector){.type = TQLSELECTOR_VARID,
                    .data = {.variable_identifier_selector = identifier}};
  return selector;
}

TQLSelector *tql_selector_function_invocation(TQLAst *ast,
                                              TQLFunctionIdentifier *identifier,
                                              TQLExpression **exprs,
                                              uint16_t expr_count) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  selector->type = TQLSELECTOR_FUNINV;
  selector->data.function_invocation_selector.identifier = identifier;
  if (expr_count > 0) {
    selector->data.function_invocation_selector.exprs =
        tql_context_alloc(ast->ctx, sizeof(TQLExpression *) * expr_count);
    memcpy(selector->data.function_invocation_selector.exprs, exprs,
           sizeof(TQLExpression *) * expr_count);
    selector->data.function_invocation_selector.expr_count = expr_count;
  } else {
    selector->data.function_invocation_selector.exprs = NULL;
    selector->data.function_invocation_selector.expr_count = 0;
  }

  return selector;
}

TQLSelector *tql_selector_negate(TQLAst *ast, TQLSelector *child) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_NEGATE,
      .data =
          {
              .negate_selector = child,
          },
  };
  return selector;
}
TQLSelector *tql_selector_and(TQLAst *ast, TQLSelector *left,
                              TQLSelector *right) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_AND,
      .data =
          {
              .and_selector =
                  {
                      .left = left,
                      .right = right,
                  },
          },
  };
  return selector;
}
TQLSelector *tql_selector_or(TQLAst *ast, TQLSelector *left,
                             TQLSelector *right) {
  TQLSelector *selector = tql_context_alloc(ast->ctx, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_OR,
      .data =
          {
              .or_selector =
                  {
                      .left = left,
                      .right = right,
                  },
          },
  };
  return selector;
}

TQLTree *tql_tree(TQLAst *ast, TQLFunction **functions, uint16_t function_count,
                  TQLDirective **directives, uint16_t directive_count) {
  TQLTree *tql_tree = tql_context_alloc(ast->ctx, sizeof(TQLTree));
  if (function_count > 0) {
    tql_tree->functions =
        tql_context_alloc(ast->ctx, sizeof(TQLFunction *) * function_count);
    memcpy(tql_tree->functions, functions,
           sizeof(TQLFunction *) * function_count);
    tql_tree->function_count = function_count;
  } else {
    tql_tree->functions = NULL;
    tql_tree->function_count = 0;
  }

  if (directive_count > 0) {
    tql_tree->directives =
        tql_context_alloc(ast->ctx, sizeof(TQLDirective *) * directive_count);
    memcpy(tql_tree->directives, directives,
           sizeof(TQLDirective *) * directive_count);
    tql_tree->directive_count = directive_count;
  } else {
    tql_tree->directives = NULL;
    tql_tree->directive_count = 0;
  }
  return tql_tree;
}

TQLFunction *tql_function(TQLAst *ast, TQLFunctionIdentifier *identifier,
                          TQLVariableIdentifier **parameters,
                          uint16_t parameter_count, TQLStatement **statements,
                          uint16_t statement_count) {
  TQLFunction *fn = tql_context_alloc(ast->ctx, sizeof(TQLFunction));
  fn->identifier = identifier;
  if (parameter_count > 0) {
    fn->parameters = tql_context_alloc(
        ast->ctx, sizeof(TQLVariableIdentifier *) * parameter_count);
    memcpy(fn->parameters, parameters,
           sizeof(TQLVariableIdentifier *) * parameter_count);
    fn->parameter_count = parameter_count;
  } else {
    fn->parameters = NULL;
    fn->parameter_count = 0;
  }

  if (statement_count > 0) {
    fn->statements =
        tql_context_alloc(ast->ctx, sizeof(TQLStatement *) * statement_count);
    memcpy(fn->statements, statements,
           sizeof(TQLStatement *) * statement_count);
    fn->statement_count = statement_count;
  } else {
    fn->statements = NULL;
    fn->statement_count = 0;
  }

  return fn;
}

TQLAst *tql_ast_new(TQLContext *ctx) {
  TQLAst *ast = malloc(sizeof(TQLAst));
  ast->ctx = ctx;
  ast->tree = NULL;
  return ast;
}

void tql_ast_free(TQLAst *ast) {
  ast->tree = NULL;
  ast->ctx = NULL;
  free(ast);
}

TQLFunction *tql_lookup_function(const TQLAst *ast, const char *string,
                                 uint32_t length) {
  for (int i = 0; i < ast->tree->function_count; i++) {
    if (string_slice_eq(*ast->tree->functions[i]->identifier,
                        (StringSlice){string, length})) {
      return ast->tree->functions[i];
    }
  }
  return NULL;
}

TQLDirective *tql_directive_target(TQLAst *ast, TQLString *target) {
  TQLDirective *directive = tql_context_alloc(ast->ctx, sizeof(TQLDirective));
  *directive = (TQLDirective){
      .type = TQLDIRECTIVE_TARGET,
      .data = {.target = target},
  };
  return directive;
}
