#ifndef _AST_H_
#define _AST_H_

#include "arena.h"
#include "context.h"
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

struct TQLExpression {
  enum { TQLEXPRESSION_SELECTOR, TQLEXPRESSION_STRING } type;
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
  enum {
    TQLSTATEMENT_SELECTOR,
    TQLSTATEMENT_ASSIGNMENT,
  } type;
  union {
    TQLSelector *selector;
    TQLAssignment *assignment;
  } data;
};

struct TQLSelector {
  enum {
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
  } type;
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
  TQLTree *tree;
  TQLContext *ctx;
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

TQLAst *tql_ast_new(TQLContext *ctx);
void tql_ast_free(TQLAst *ast);

TQLTree *tql_tree(TQLAst *ast, TQLFunction **functions, uint16_t function_count,
                  TQLDirective **directives, uint16_t directive_count);

TQLDirective *tql_directive_target(TQLAst *ast, TQLString *target);

TQLFunction *tql_function(TQLAst *ast, TQLFunctionIdentifier *identifier,
                          TQLVariableIdentifier **parameters,
                          uint16_t parameter_count, TQLStatement **statements,
                          uint16_t statement_count);

TQLSelector *tql_selector_self(TQLAst *ast);
TQLSelector *tql_selector_nodetype(TQLAst *ast,
                                   TQLVariableIdentifier *node_type);
TQLSelector *tql_selector_fieldname(TQLAst *ast, TQLSelector *parent,
                                    TQLString *field);
TQLSelector *tql_selector_child(TQLAst *ast, TQLSelector *parent,
                                TQLSelector *child);
TQLSelector *tql_selector_descendant(TQLAst *ast, TQLSelector *parent,
                                     TQLSelector *child);
TQLSelector *tql_selector_block(TQLAst *ast, TQLSelector *parent,
                                TQLStatement **statements,
                                uint32_t statement_count);
TQLSelector *tql_selector_varid(TQLAst *ast, TQLVariableIdentifier *identifier);
TQLSelector *tql_selector_function_invocation(TQLAst *ast,
                                              TQLFunctionIdentifier *identifier,
                                              TQLExpression **exprs,
                                              uint16_t expr_count);
TQLSelector *tql_selector_negate(TQLAst *ast, TQLSelector *selector);
TQLSelector *tql_selector_or(TQLAst *ast, TQLSelector *left,
                             TQLSelector *right);
TQLSelector *tql_selector_and(TQLAst *ast, TQLSelector *left,
                              TQLSelector *right);

TQLStatement *tql_statement_selector(TQLAst *ast, TQLSelector *selector);
TQLStatement *tql_statement_assignment(TQLAst *ast, TQLAssignment *assignment);

TQLAssignment *tql_assignment(TQLAst *ast,
                              TQLVariableIdentifier *variable_identifier,
                              TQLExpression *expression);

TQLExpression *tql_expression_selector(TQLAst *ast, TQLSelector *selector);
TQLExpression *tql_expression_string(TQLAst *ast, TQLString *string);

TQLString *tql_string(TQLAst *ast, const char *string, uint32_t length);

TQLFunction *tql_lookup_function(const TQLAst *ast, const char *string,
                                 uint32_t length);

#endif /* _AST_H_ */
