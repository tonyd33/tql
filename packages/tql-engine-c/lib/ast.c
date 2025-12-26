#include "ast.h"
#include <stdio.h>
#include <string.h>

#define AST_ARENA_SIZE 32768
#define STRING_POOL_CAPACITY 8192

StringPool *string_pool_new() {
  StringPool *string_pool = malloc(sizeof(StringPool));
  string_pool->string_count = 0;
  string_pool->string_capacity = 256;
  string_pool->pool_capacity = STRING_POOL_CAPACITY;
  string_pool->strings = malloc(STRING_POOL_CAPACITY);
  string_pool->offsets =
      malloc(sizeof(uint32_t) * string_pool->string_capacity);
  return string_pool;
}

char *string_pool_alloc(StringPool *string_pool, const char *string,
                        uint32_t length) {
  uint32_t offset = 0;
  uint32_t string_count = 0;
  char *pooled_string = NULL;
  for (string_count = 0; string_count < string_pool->string_count;
       string_count++) {
    offset = string_pool->offsets[string_count];
    pooled_string = &string_pool->strings[offset];
    if (strncmp(pooled_string, string, length) == 0) {
      return pooled_string;
    }
  }

  if (string_pool->string_capacity - offset <= length ||
      string_count >= string_pool->string_capacity) {
    return NULL;
  } else {
    uint32_t next_offset =
        pooled_string == NULL ? 0 : offset + strlen(pooled_string) + 2;
    strncpy(&string_pool->strings[next_offset], string, length);
    string_pool->strings[next_offset + length] = '\0';
    string_pool->offsets[string_pool->string_count++] = next_offset;
    return &string_pool->strings[next_offset];
  }
}

void string_pool_free(StringPool *string_pool) {
  free(string_pool->offsets);
  string_pool->offsets = NULL;
  free(string_pool->strings);
  string_pool->strings = NULL;
  string_pool->pool_capacity = 0;
  string_pool->string_capacity = 0;
  string_pool->string_count = 0;
  free(string_pool);
}

TQLString *tql_string_new(TQLAst *ast, const char *string, size_t length) {
  TQLString *tql_string = arena_alloc(ast->arena, sizeof(TQLString));
  tql_string->string = string_pool_alloc(ast->string_pool, string, length);
  assert(tql_string->string != NULL);
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

TQLExpression *tql_expression_new(TQLAst *ast, TQLSelector *selector) {
  TQLExpression *expression = arena_alloc(ast->arena, sizeof(TQLExpression));
  *expression = (TQLExpression){.type = TQLEXPRESSION_SELECTOR,
                                .data = {.selector = selector}};
  return expression;
}

TQLStatement *tql_statement_condition_new(TQLAst *ast,
                                          TQLCondition *condition) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
      .type = TQLSTATEMENT_CONDITION,
      .data = {.condition = condition},
  };
  return statement;
}

TQLSelector *tql_selector_universal_new(TQLAst *ast) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  *selector = (TQLSelector){
      .type = TQLSELECTOR_UNIVERSAL,
  };
  return selector;
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

TQLTree *tql_tree_new(TQLAst *ast, TQLSelector **selectors,
                      uint32_t selector_count) {
  TQLTree *tql_tree = arena_alloc(ast->arena, sizeof(TQLTree));
  if (selector_count > 0) {
    tql_tree->selectors =
        arena_alloc(ast->arena, sizeof(TQLSelector *) * selector_count);
    memcpy(tql_tree->selectors, selectors,
           sizeof(TQLSelector *) * selector_count);
    tql_tree->selector_count = selector_count;
  } else {
    tql_tree->selectors = NULL;
    tql_tree->selector_count = 0;
  }
  return tql_tree;
}

TQLAst *tql_ast_new(const char *string, size_t length) {
  TQLAst *ast = malloc(sizeof(TQLAst));

  ast->arena = arena_new(AST_ARENA_SIZE);

  ast->string_pool = string_pool_new();

  ast->source_length = length;
  ast->source = malloc(sizeof(char) * length);
  strncpy(ast->source, string, length);

  return ast;
}

void tql_ast_free(TQLAst *ast) {
  if (ast->source != NULL) {
    free(ast->source);
    ast->source = NULL;
  }
  ast->source_length = 0;

  if (ast->string_pool != NULL) {
    string_pool_free(ast->string_pool);
    ast->string_pool = NULL;
  }

  if (ast->arena != NULL) {
    arena_free(ast->arena);
    ast->arena = NULL;
  }
  free(ast);
}

TQLCondition *tql_condition_empty_new(TQLAst *ast, TQLExpression *expression) {
  TQLCondition *condition = arena_alloc(ast->arena, sizeof(TQLCondition));
  *condition =
      (TQLCondition){.type = TQLCONDITION_EMPTY,
                     .data = {.empty_condition = {.expression = expression}}};
  return condition;
}
