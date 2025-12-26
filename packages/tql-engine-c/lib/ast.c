#include "ast.h"
#include <string.h>
#include <stdio.h>

#define AST_ARENA_SIZE 32768
#define STRING_POOL_CAPACITY 8192

StringPool *string_pool_new() {
  StringPool *string_pool = malloc(sizeof(StringPool));
  string_pool->string_count = 0;
  string_pool->string_capacity = 256;
  string_pool->pool_capacity = STRING_POOL_CAPACITY;
  string_pool->strings = malloc(STRING_POOL_CAPACITY);
  string_pool->offsets = malloc(sizeof(uint32_t) * string_pool->string_capacity);
  return string_pool;
}

char *string_pool_alloc(StringPool *string_pool, const char *string, uint32_t length) {
  uint32_t offset = 0;
  uint32_t string_count = 0;
  char *pooled_string = NULL;
  for (string_count = 0; string_count < string_pool->string_count; string_count++) {
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

TQLInlineNodeOperation *tql_inline_node_operation_assignment_new(TQLAst *ast, TQLVariableIdentifier *identifier) {
  TQLInlineNodeOperation *inline_node_operation = arena_alloc(ast->arena, sizeof(TQLInlineNodeOperation));
  *inline_node_operation = (TQLInlineNodeOperation){
    .type = TQLINLINENODEOP_ASSIGNMENT,
    .data = {
      .identifier = identifier,
    },
  };
  return inline_node_operation;
}

TQLStatement *tql_statement_query_new(TQLAst *ast, TQLQuery *query) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
    .data = {.query = query},
  };
  return statement;
}
TQLStatement *tql_statement_assignment_new(TQLAst *ast, TQLAssignment *assignment) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
    .data = {.assignment = assignment},
  };
  return statement;
}
TQLStatement *tql_statement_condition_new(TQLAst *ast, TQLCondition *condition) {
  TQLStatement *statement = arena_alloc(ast->arena, sizeof(TQLStatement));
  *statement = (TQLStatement){
    .data = {.condition = condition},
  };
  return statement;
}

TQLPureSelector *tql_pure_selector_universal_new(TQLAst *ast) {
  TQLPureSelector *pure_selector = arena_alloc(ast->arena, sizeof(TQLPureSelector));
  *pure_selector = (TQLPureSelector){
    .type = TQLSELECTOR_UNIVERSAL,
  };
  return pure_selector;
}

TQLPureSelector *tql_pure_selector_nodetype_new(TQLAst *ast, TQLVariableIdentifier *node_type) {
  TQLPureSelector *pure_selector = arena_alloc(ast->arena, sizeof(TQLPureSelector));
  *pure_selector = (TQLPureSelector){
    .type = TQLSELECTOR_NODETYPE,
    .data = {
      .node_type_selector = node_type,
    },
  };
  return pure_selector;
}

TQLPureSelector *tql_pure_selector_fieldname_new(TQLAst *ast, TQLSelector *parent, TQLString *field) {
  TQLPureSelector *pure_selector = arena_alloc(ast->arena, sizeof(TQLPureSelector));
  *pure_selector = (TQLPureSelector){
    .type = TQLSELECTOR_FIELDNAME,
    .data = {
      .field_name_selector = {
          .parent = parent,
          .field = field,
      },
    },
  };
  return pure_selector;
}

TQLPureSelector *tql_pure_selector_child_new(TQLAst *ast, TQLSelector *parent, TQLSelector *child) {
  TQLPureSelector *pure_selector = arena_alloc(ast->arena, sizeof(TQLPureSelector));
  *pure_selector = (TQLPureSelector){
    .type = TQLSELECTOR_CHILD,
    .data = {
      .child_selector = {
          .parent = parent,
          .child = child,
      },
    },
  };
  return pure_selector;
}

TQLPureSelector *tql_pure_selector_descendant_new(TQLAst *ast, TQLSelector *parent, TQLSelector *child) {
  TQLPureSelector *pure_selector = arena_alloc(ast->arena, sizeof(TQLPureSelector));
  *pure_selector = (TQLPureSelector){
    .type = TQLSELECTOR_DESCENDANT,
    .data = {
      .descendant_selector = {
          .parent = parent,
          .child = child,
      },
    },
  };
  return pure_selector;
}

TQLSelector *tql_selector_new(TQLAst *ast, TQLPureSelector *pure_selector, TQLInlineNodeOperation **node_operations, size_t node_operation_count) {
  TQLSelector *selector = arena_alloc(ast->arena, sizeof(TQLSelector));
  selector->pure_selector = pure_selector;

  if (node_operation_count > 0) {
    TQLInlineNodeOperation **node_operations_copy = arena_alloc(ast->arena, sizeof(TQLInlineNodeOperation*) * node_operation_count);
    memcpy(node_operations_copy, node_operations, sizeof(TQLInlineNodeOperation*) * node_operation_count);
    selector->node_operations = node_operations_copy;
    selector->node_operation_count = node_operation_count;
  } else {
    selector->node_operations = NULL;
    selector->node_operation_count = 0;
  }
  return selector;
}

TQLQuery *tql_query_new(TQLAst *ast, TQLSelector *selector, TQLStatement **statements, size_t statement_count) {
  TQLQuery *query = arena_alloc(ast->arena, sizeof(TQLQuery));
  query->selector = selector;

  if (statement_count > 0) {
    TQLStatement **statements_copy = arena_alloc(ast->arena, sizeof(TQLStatement*) * statement_count);
    memcpy(statements_copy, statements, sizeof(TQLStatement*) * statement_count);
    query->statements = statements_copy;
    query->statement_count = statement_count;
  } else {
    query->statements = NULL;
    query->statement_count = 0;
  }
  return query;
}

TQLTree *tql_tree_new(TQLAst *ast, TQLQuery **queries, size_t query_count) {
  TQLTree *tql_tree = arena_alloc(ast->arena, sizeof(TQLTree));
  if (query_count > 0) {
    TQLQuery **queries_copy = arena_alloc(ast->arena, sizeof(TQLQuery*) * query_count);
    memcpy(queries_copy, queries, sizeof(TQLQuery*) * query_count);
    tql_tree->queries = queries_copy;
    tql_tree->query_count = query_count;
  } else {
    tql_tree->queries = NULL;
    tql_tree->query_count = 0;
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
