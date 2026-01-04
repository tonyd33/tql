#ifndef _AST_H_
#define _AST_H_

#include "arena.h"
#include "ds.h"

typedef StringSlice TQLString;

typedef struct TQLAst TQLAst;
typedef struct TQLTree TQLTree;
typedef struct TQLFunction TQLFunction;
typedef struct TQLSelector TQLSelector;
typedef struct TQLPureSelector TQLPureSelector;
typedef struct TQLExpression TQLExpression;
typedef struct TQLQuery TQLQuery;
typedef struct TQLAssignment TQLAssignment;
typedef struct TQLStatement TQLStatement;
typedef struct TQLDirective TQLDirective;
typedef struct TQLParameter TQLParameter;
typedef struct TQLFunctionInvocation TQLFunctionInvocation;
typedef struct TQLAstStats TQLAstStats;

typedef TQLString TQLVariableIdentifier;
typedef TQLString TQLFunctionIdentifier;

typedef enum TQLExpressionType {
  TQLEXPRESSION_SELECTOR,
  TQLEXPRESSION_STRING
} TQLExpressionType;

typedef enum TQLStatementType {
  TQLSTATEMENT_SELECTOR,
  TQLSTATEMENT_ASSIGNMENT,
} TQLStatementType;

typedef enum TQLSelectorType {
  TQLSELECTOR_SELF,
  TQLSELECTOR_NODETYPE,
  TQLSELECTOR_FIELDNAME,
  TQLSELECTOR_CHILD,
  TQLSELECTOR_DESCENDANT,
  TQLSELECTOR_BLOCK,
  TQLSELECTOR_VARID,
  TQLSELECTOR_FUNINV,
  TQLSELECTOR_NEGATE,
  TQLSELECTOR_AND,
  TQLSELECTOR_OR,
} TQLSelectorType;

struct TQLExpression {
  TQLExpressionType type;
  union {
    TQLSelector *selector;
    TQLString *string;
  } data;
};

struct TQLAssignment {
  TQLVariableIdentifier *variable_identifier;
  TQLExpression *expression;
};

struct TQLStatement {
  TQLStatementType type;
  union {
    TQLSelector *selector;
    TQLAssignment *assignment;
  } data;
};

struct TQLSelector {
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
      uint16_t statement_count;
    } block_selector;

    TQLVariableIdentifier *variable_identifier_selector;

    struct {
      TQLFunctionIdentifier *identifier;
      TQLExpression **exprs;
      uint16_t expr_count;
    } function_invocation_selector;

    TQLSelector *negate_selector;

    struct {
      TQLSelector *left;
      TQLSelector *right;
    } or_selector;

    struct {
      TQLSelector *left;
      TQLSelector *right;
    } and_selector;
  } data;
};

struct TQLDirective {
  enum {
    TQLDIRECTIVE_TARGET,
    TQLDIRECTIVE_INCLUDE,
  } type;
  union {
    TQLString *target;
    TQLString *import;
  } data;
};

struct TQLTree {
  TQLFunction **functions;
  uint16_t function_count;
  TQLDirective **directives;
  uint16_t directive_count;
};

struct TQLAst {
  Arena *arena;
  StringInterner *string_interner;
  TQLTree *tree;
  char *source;
  size_t source_length;
};

struct TQLFunction {
  TQLFunctionIdentifier *identifier;
  TQLVariableIdentifier **parameters;
  uint16_t parameter_count;
  TQLStatement **statements;
  uint16_t statement_count;
};

struct TQLAstStats {
  uint32_t arena_alloc;
};

TQLAst *tql_ast_new(const char *string, size_t length, StringInterner *interner);
void tql_ast_free(TQLAst *ast);
TQLAstStats tql_ast_stats(const TQLAst *ast);

TQLTree *tql_tree_new(TQLAst *ast, TQLFunction **functions,
                      uint16_t function_count, TQLDirective **directives,
                      uint16_t directive_count);

TQLDirective *tql_directive_target(TQLAst *ast, TQLString *target);

TQLFunction *tql_function_new(TQLAst *ast, TQLFunctionIdentifier *identifier,
                              TQLVariableIdentifier **parameters,
                              uint16_t parameter_count,
                              TQLStatement **statements,
                              uint16_t statement_count);

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
TQLSelector *tql_selector_function_invocation_new(
    TQLAst *ast, TQLFunctionIdentifier *identifier, TQLExpression **exprs,
    uint16_t expr_count);
TQLSelector *tql_selector_negate(TQLAst *ast, TQLSelector *selector);
TQLSelector *tql_selector_or(TQLAst *ast, TQLSelector *left,
                             TQLSelector *right);
TQLSelector *tql_selector_and(TQLAst *ast, TQLSelector *left,
                              TQLSelector *right);

TQLStatement *tql_statement_selector_new(TQLAst *ast, TQLSelector *selector);
TQLStatement *tql_statement_assignment_new(TQLAst *ast,
                                           TQLAssignment *assignment);

TQLAssignment *tql_assignment_new(TQLAst *ast,
                                  TQLVariableIdentifier *variable_identifier,
                                  TQLExpression *expression);

TQLExpression *tql_expression_selector_new(TQLAst *ast, TQLSelector *selector);
TQLExpression *tql_expression_string_new(TQLAst *ast, TQLString *string);

TQLString *tql_string_new(TQLAst *ast, const char *string, uint32_t length);

TQLFunction *tql_lookup_function(const TQLAst *ast, const char *string,
                                 uint32_t length);

#endif /* _AST_H_ */
