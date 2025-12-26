#ifndef _AST_H_
#define _AST_H_

#include "dyn_array.h"
#include "arena.h"

// TODO: This is so horribly storage-inefficient...

typedef struct TQLString {
  const char *string;
  size_t length;
} TQLString;
typedef TQLString TQLVariableIdentifier;

struct StringPool;
typedef struct StringPool StringPool;

struct TQLSelector;
typedef struct TQLSelector TQLSelector;

struct TQLPureSelector;
typedef struct TQLPureSelector TQLPureSelector;

typedef struct TQLSelector TQLExpression;
struct TQLQuery;
typedef struct TQLQuery TQLQuery;

struct TQLAssignment;
typedef struct TQLAssignment TQLAssignment;

struct TQLCondition;
typedef struct TQLCondition TQLCondition;

typedef struct TQLAssignment {
  TQLVariableIdentifier *variable_identifier;
  TQLExpression *expression;
} TQLAssignment;

typedef enum TQLConditionType {
  TQLCONDITION_TEXTEQ,
  TQLCONDITION_EMPTY,
  TQLCONDITION_BINARY,
} TQLConditionType;

typedef enum TQLBinaryConditionType {
  TQLBINARYCONDITION_OR,
  TQLBINARYCONDITION_AND,
} TQLBinaryConditionType;

typedef struct TQLCondition {
  TQLConditionType type;
  union {
    struct {
      TQLExpression *expression;
      TQLString *string;
    } text_eq_condition;

    struct {
      TQLExpression *expression;
    } empty_condition;

    struct {
      TQLBinaryConditionType combinator;
      TQLCondition *condition_1;
      TQLCondition *condition_2;
    } binary_condition;
  } data;
} TQLCondition;

typedef enum TQLStatementType {
  TQLSTATEMENT_QUERY,
  TQLSTATEMENT_ASSIGNMENT,
  TQLSTATEMENT_CONDITION,
} TQLStatementType;

typedef struct TQLStatement {
  TQLStatementType type;
  union {
    TQLQuery *query;
    TQLAssignment *assignment;
    TQLCondition *condition;
  } data;
} TQLStatement;

typedef enum TQLSelectorType {
  TQLSELECTOR_UNIVERSAL,
  TQLSELECTOR_NODETYPE,
  TQLSELECTOR_FIELDNAME,
  TQLSELECTOR_CHILD,
  TQLSELECTOR_DESCENDANT,
} TQLSelectorType;

typedef struct TQLPureSelector {
  TQLSelectorType type;
  union {
    TQLVariableIdentifier *node_type_selector;

    struct {
      TQLSelector *parent;
      TQLString *field;
    } field_name_selector;

    struct {
      TQLSelector *parent;
      TQLSelector *child;
    } child_selector;

    struct {
      TQLSelector *parent;
      TQLSelector *child;
    } descendant_selector;
  } data;
} TQLPureSelector;

typedef enum TQLInlineNodeOperationType {
  TQLINLINENODEOP_ASSIGNMENT,
} TQLInlineNodeOperationType;

typedef struct TQLInlineNodeOperation {
  TQLInlineNodeOperationType type;
  union {
    TQLVariableIdentifier *identifier;
  } data;
} TQLInlineNodeOperation;

typedef struct TQLSelector {
  TQLPureSelector *pure_selector;
  TQLInlineNodeOperation **node_operations;
  uint16_t node_operation_count;
} TQLSelector;

typedef struct TQLQuery {
  TQLSelector *selector;
  TQLStatement **statements;
  uint16_t statement_count;
} TQLQuery;

typedef struct TQLTree {
  TQLQuery **queries;
  uint16_t query_count;
} TQLTree;

typedef struct StringPool {
  uint32_t string_count;
  uint32_t string_capacity;
  uint32_t pool_capacity;
  uint32_t *offsets;
  char *strings;
} StringPool;

typedef struct TQLAst {
  Arena *arena;
  StringPool *string_pool;
  TQLTree *tree;
  char *source;
  size_t source_length;
} TQLAst;

TQLString *tql_string_new(TQLAst *ast, const char *string, size_t length);

TQLExpression *tql_expression_new(TQLAst *ast);

TQLCondition *tql_condition_texteq_new(TQLAst *ast, TQLExpression *expression, TQLString *string);
TQLCondition *tql_condition_empty_new(TQLAst *ast, TQLExpression *expression);
TQLCondition *tql_condition_binary_new(TQLAst *ast, TQLCondition *condition_1, TQLBinaryConditionType binop, TQLCondition *condition_2);

TQLAssignment *tql_assignment_new(TQLAst *ast, TQLVariableIdentifier *variable_identifier, TQLExpression *expression);

TQLStatement *tql_statement_query_new(TQLAst *ast, TQLQuery *query);
TQLStatement *tql_statement_assignment_new(TQLAst *ast, TQLAssignment *assignment);
TQLStatement *tql_statement_condition_new(TQLAst *ast, TQLCondition *condition);

TQLInlineNodeOperation *tql_inline_node_operation_assignment_new(TQLAst *ast, TQLVariableIdentifier *identifier);

TQLPureSelector *tql_pure_selector_universal_new(TQLAst *ast);
TQLPureSelector *tql_pure_selector_nodetype_new(TQLAst *ast, TQLVariableIdentifier *node_type);
TQLPureSelector *tql_pure_selector_fieldname_new(TQLAst *ast, TQLSelector *parent, TQLString *field);
TQLPureSelector *tql_pure_selector_child_new(TQLAst *ast, TQLSelector *parent, TQLSelector *child);
TQLPureSelector *tql_pure_selector_descendant_new(TQLAst *ast, TQLSelector *parent, TQLSelector *child);

TQLSelector *tql_selector_new(TQLAst *ast, TQLPureSelector *pure_selector, TQLInlineNodeOperation **node_operations, size_t node_operations_count);

TQLQuery *tql_query_new(TQLAst *ast, TQLSelector *selector, TQLStatement **statements, size_t statement_count);

TQLTree *tql_tree_new(TQLAst *ast, TQLQuery **queries, size_t query_count);

TQLAst *tql_ast_new();
void tql_ast_free(TQLAst *ast);

#endif /* _AST_H_ */
