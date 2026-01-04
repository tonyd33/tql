#include "ast.h"
#include <stdio.h>
#include <string.h>

#define AST_ARENA_SIZE 32768

TQLString *tql_string_new(TQLAst *ast, const char *string, uint32_t length) {
  TQLString *tql_string = arena_alloc(ast->arena, sizeof(TQLString));
  *tql_string = string_intern(ast->string_interner, string, length);
  tql_string->length = length;
  return tql_string;
}

TQLStatement *tql_statement_selector_new(TQLAst *ast, TQLSelector *selector) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
      .type = TQLSTATEMENT_SELECTOR,
      .data = {.selector = selector},
  };
  return statement;
}
TQLStatement *tql_statement_assignment_new(TQLAst *ast,
                                           TQLAssignment *assignment) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
      .type = TQLSTATEMENT_ASSIGNMENT,
      .data = {.assignment = assignment},
  };
  return statement;
}

TQLAssignment *tql_assignment_new(TQLAst *ast,
                                  TQLVariableIdentifier *variable_identifier,
                                  TQLExpression *expression) {
  TQLAssignment *assignment = arena_alloc(ast->arena, sizeof(TQLAssignment));
  *assignment = (TQLAssignment){
      .variable_identifier = variable_identifier,
      .expression = expression,
  };
  return assignment;
}

TQLExpression *tql_expression_selector_new(TQLAst *ast, TQLSelector *selector) {
  TQLExpression *expression = arena_alloc(ast->arena, sizeof(TQLExpression));
  *expression = (TQLExpression){.type = TQLEXPRESSION_SELECTOR,
                                .data = {.selector = selector}};
  return expression;
}

TQLExpression *tql_expression_string_new(TQLAst *ast, TQLString *string) {
  TQLExpression *expression = arena_alloc(ast->arena, sizeof(TQLExpression));
  *expression =
      (TQLExpression){.type = TQLEXPRESSION_STRING, .data = {.string = string}};
  return expression;
}

TQLSelector *tql_selector_self_new(TQLAst *ast) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_SELF,
  };
  return selector;
}

TQLSelector *tql_selector_nodetype_new(TQLAst *ast,
                                       TQLVariableIdentifier *node_type) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_NODETYPE,
      .data =
          {
              .node_type_selector = node_type,
          },
  };
  return selector;
}

TQLSelector *tql_selector_fieldname_new(TQLAst *ast, TQLSelector *parent,
                                        TQLString *field) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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

TQLSelector *tql_selector_child_new(TQLAst *ast, TQLSelector *parent,
                                    TQLSelector *child) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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

TQLSelector *tql_selector_descendant_new(TQLAst *ast, TQLSelector *parent,
                                         TQLSelector *child) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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
TQLSelector *tql_selector_block_new(TQLAst *ast, TQLSelector *parent,
                                    TQLStatement **statements,
                                    uint32_t statement_count) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  selector->type = TQLSELECTOR_BLOCK;
  selector->data.block_selector.parent = parent;
  if (statement_count > 0) {
    selector->data.block_selector.statements =
        arena_alloc(ast->arena, sizeof(TQLStatement *) * statement_count);
    memcpy(selector->data.block_selector.statements, statements,
           sizeof(TQLStatement *) * statement_count);
    selector->data.block_selector.statement_count = statement_count;
  } else {
    selector->data.block_selector.statements = NULL;
    selector->data.block_selector.statement_count = 0;
  }
  return selector;
}

TQLSelector *tql_selector_varid_new(TQLAst *ast,
                                    TQLVariableIdentifier *identifier) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  *selector =
      (TQLSelector){.type = TQLSELECTOR_VARID,
                    .data = {.variable_identifier_selector = identifier}};
  return selector;
}

TQLSelector *tql_selector_function_invocation_new(
    TQLAst *ast, TQLFunctionIdentifier *identifier, TQLExpression **exprs,
    uint16_t expr_count) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  selector->type = TQLSELECTOR_FUNINV;
  selector->data.function_invocation_selector.identifier = identifier;
  if (expr_count > 0) {
    selector->data.function_invocation_selector.exprs =
        arena_alloc(ast->arena, sizeof(TQLExpression *) * expr_count);
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
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
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

TQLTree *tql_tree_new(TQLAst *ast, TQLFunction **functions,
                      uint16_t function_count, TQLDirective **directives,
                      uint16_t directive_count) {
  TQLTree *tql_tree = arena_alloc(ast->arena, sizeof(TQLTree));
  if (function_count > 0) {
    tql_tree->functions =
        arena_alloc(ast->arena, sizeof(TQLFunction *) * function_count);
    memcpy(tql_tree->functions, functions,
           sizeof(TQLFunction *) * function_count);
    tql_tree->function_count = function_count;
  } else {
    tql_tree->functions = NULL;
    tql_tree->function_count = 0;
  }

  if (directive_count > 0) {
    tql_tree->directives =
        arena_alloc(ast->arena, sizeof(TQLDirective *) * directive_count);
    memcpy(tql_tree->directives, directives,
           sizeof(TQLDirective *) * directive_count);
    tql_tree->directive_count = directive_count;
  } else {
    tql_tree->directives = NULL;
    tql_tree->directive_count = 0;
  }
  return tql_tree;
}

TQLFunction *tql_function_new(TQLAst *ast, TQLFunctionIdentifier *identifier,
                              TQLVariableIdentifier **parameters,
                              uint16_t parameter_count,
                              TQLStatement **statements,
                              uint16_t statement_count) {
  TQLFunction *fn = arena_alloc(ast->arena, sizeof(TQLFunction));
  fn->identifier = identifier;
  if (parameter_count > 0) {
    fn->parameters = arena_alloc(ast->arena, sizeof(TQLVariableIdentifier *) *
                                                 parameter_count);
    memcpy(fn->parameters, parameters,
           sizeof(TQLVariableIdentifier *) * parameter_count);
    fn->parameter_count = parameter_count;
  } else {
    fn->parameters = NULL;
    fn->parameter_count = 0;
  }

  if (statement_count > 0) {
    fn->statements =
        arena_alloc(ast->arena, sizeof(TQLStatement *) * statement_count);
    memcpy(fn->statements, statements,
           sizeof(TQLStatement *) * statement_count);
    fn->statement_count = statement_count;
  } else {
    fn->statements = NULL;
    fn->statement_count = 0;
  }

  return fn;
}

TQLAst *tql_ast_new(const char *src, size_t length, StringInterner *interner) {
  TQLAst *ast = malloc(sizeof(TQLAst));

  ast->arena = arena_new(AST_ARENA_SIZE);

  ast->string_interner = interner;

  ast->source_length = length;
  ast->source = malloc(sizeof(char) * length);
  strncpy(ast->source, src, length);

  return ast;
}

void tql_ast_free(TQLAst *ast) {
  if (ast->source != NULL) {
    free(ast->source);
    ast->source = NULL;
  }
  ast->source_length = 0;

  ast->string_interner = NULL;

  if (ast->arena != NULL) {
    arena_free(ast->arena);
    ast->arena = NULL;
  }
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
  TQLDirective *directive = arena_alloc(ast->arena, sizeof(TQLDirective));
  *directive = (TQLDirective){
      .type = TQLDIRECTIVE_TARGET,
      .data = {.target = target},
  };
  return directive;
}

TQLAstStats tql_ast_stats(const TQLAst *ast) {
  return (TQLAstStats){
      .arena_alloc = ast->arena->offset,
  };
}
