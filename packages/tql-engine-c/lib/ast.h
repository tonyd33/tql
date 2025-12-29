#ifndef _AST_H_
#define _AST_H_

#include "arena.h"
#include "ds.h"

// FIXME: This is so horribly storage-inefficient... each AST node is ~16-24
// bytes!

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

struct TQLExpression;
typedef struct TQLExpression TQLExpression;

struct TQLQuery;
typedef struct TQLQuery TQLQuery;

struct TQLAssignment;
typedef struct TQLAssignment TQLAssignment;

struct TQLCondition;
typedef struct TQLCondition TQLCondition;

typedef enum TQLExpressionType { TQLEXPRESSION_SELECTOR } TQLExpressionType;

typedef struct TQLExpression {
  TQLExpressionType type;
  union {
    TQLSelector *selector;
  } data;
} TQLExpression;

typedef struct TQLAssignment {
  TQLVariableIdentifier *variable_identifier;
  TQLExpression *expression;
} TQLAssignment;

typedef enum TQLConditionType {
  TQLCONDITION_TEXTEQ,
  TQLCONDITION_EMPTY,
  TQLCONDITION_AND,
  TQLCONDITION_OR,
} TQLConditionType;

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
      TQLCondition *condition_1;
      TQLCondition *condition_2;
    } binary_condition;
  } data;
} TQLCondition;

typedef enum TQLStatementType {
  TQLSTATEMENT_SELECTOR,
  TQLSTATEMENT_ASSIGNMENT,
  TQLSTATEMENT_CONDITION,
} TQLStatementType;

typedef struct TQLStatement {
  TQLStatementType type;
  union {
    TQLSelector *selector;
    TQLAssignment *assignment;
    TQLCondition *condition;
  } data;
} TQLStatement;

typedef enum TQLSelectorType {
  TQLSELECTOR_SELF,
  TQLSELECTOR_UNIVERSAL,
  TQLSELECTOR_NODETYPE,
  TQLSELECTOR_FIELDNAME,
  TQLSELECTOR_CHILD,
  TQLSELECTOR_DESCENDANT,
  TQLSELECTOR_BLOCK,
  TQLSELECTOR_VARID,
} TQLSelectorType;

typedef struct TQLSelector {
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

    struct {
      TQLSelector *parent;
      TQLStatement **statements;
      uint32_t statement_count;
    } block_selector;

    TQLVariableIdentifier *variable_identifier_selector;
  } data;
} TQLSelector;

typedef struct TQLTree {
  TQLSelector **selectors;
  uint16_t selector_count;
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

TQLAst *tql_ast_new(const char *string, size_t length);
void tql_ast_free(TQLAst *ast);

TQLTree *tql_tree_new(TQLAst *ast, TQLSelector **selectors,
                      uint32_t selector_count);

TQLSelector *tql_selector_universal_new(TQLAst *ast);
TQLSelector *tql_selector_self_new(TQLAst *ast);
TQLSelector *tql_selector_nodetype_new(TQLAst *ast,
                                       TQLVariableIdentifier *node_type);
TQLSelector *tql_selector_fieldname_new(TQLAst *ast, TQLSelector *parent,
                                        TQLString *field);
TQLSelector *tql_selector_child_new(TQLAst *ast, TQLSelector *parent,
                                    TQLSelector *child);
TQLSelector *tql_selector_descendant_new(TQLAst *ast, TQLSelector *parent,
                                         TQLSelector *child);
TQLSelector *tql_selector_block_new(TQLAst *ast, TQLSelector *parent,
                                    TQLStatement **statements,
                                    uint32_t statement_count);
TQLSelector *tql_selector_varid_new(TQLAst *ast,
                                    TQLVariableIdentifier *identifier);

TQLStatement *tql_statement_selector_new(TQLAst *ast, TQLSelector *selector);
TQLStatement *tql_statement_assignment_new(TQLAst *ast,
                                           TQLAssignment *assignment);
TQLStatement *tql_statement_condition_new(TQLAst *ast, TQLCondition *condition);

TQLCondition *tql_condition_texteq_new(TQLAst *ast, TQLExpression *expression,
                                       TQLString *string);
TQLCondition *tql_condition_empty_new(TQLAst *ast, TQLExpression *expression);
TQLCondition *tql_condition_and_new(TQLAst *ast, TQLCondition *condition_1,
                                    TQLCondition *condition_2);
TQLCondition *tql_condition_or_new(TQLAst *ast, TQLCondition *condition_1,
                                   TQLCondition *condition_2);

TQLAssignment *tql_assignment_new(TQLAst *ast,
                                  TQLVariableIdentifier *variable_identifier,
                                  TQLExpression *expression);

TQLExpression *tql_expression_new(TQLAst *ast, TQLSelector *selector);

TQLString *tql_string_new(TQLAst *ast, const char *string, size_t length);

#endif /* _AST_H_ */
