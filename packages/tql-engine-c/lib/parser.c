#include "parser.h"
#include "ast.h"
#include "tree_sitter/api.h"
#include <stdio.h>

#define assert_node_type(node, node_type)                                      \
  assert(ts_node_symbol((node)) ==                                             \
         ts_language_symbol_for_name(tree_sitter_tql(), (node_type),           \
                                     strlen((node_type)), true))
struct TQLParser {
  TSParser *ts_parser;
};

/* TODO: Use symbol ids/field ids */

const TSLanguage *tree_sitter_tql(void);

static inline TQLSelector *parse_selector(TQLAst *ast, TSNode node);
static inline TQLStatement *parse_statement(TQLAst *ast, TSNode node);
static inline TQLFunction *parse_function(TQLAst *ast, TSNode node);

TQLParser *tql_parser_new() {
  TQLParser *parser = malloc(sizeof(TQLParser));
  parser->ts_parser = ts_parser_new();
  ts_parser_set_language(parser->ts_parser, tree_sitter_tql());
  return parser;
}

static TQLString *parse_identifier(TQLAst *ast, TSNode node) {
  assert(!ts_node_is_null(node));
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  return tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);
}

static TQLVariableIdentifier *parse_variable_identifier(TQLAst *ast,
                                                        TSNode node) {
  return parse_identifier(ast, node);
}

static TQLString *parse_string_literal(TQLAst *ast, TSNode node) {
  TSNode content_node =
      ts_node_child_by_field_name(node, "content", strlen("content"));
  assert(!ts_node_is_null(content_node));

  uint32_t start_byte = ts_node_start_byte(content_node);
  uint32_t end_byte = ts_node_end_byte(content_node);
  return tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);
}

static TQLExpression *parse_expression(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "selector") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_expression_selector_new(ast, parse_selector(ast, inner_node));
  } else if (strcmp(node_type, "string_literal") == 0) {
    return tql_expression_string_new(ast, parse_string_literal(ast, node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown expression");
    return NULL;
  }
}

static TQLAssignment *parse_tql_assignment(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "explicit_assignment") == 0) {
    TSNode identifier_node =
        ts_node_child_by_field_name(node, "identifier", strlen("identifier"));
    assert(!ts_node_is_null(identifier_node));
    TSNode expression_node =
        ts_node_child_by_field_name(node, "expression", strlen("expression"));
    assert(!ts_node_is_null(expression_node));
    return tql_assignment_new(ast,
                              parse_variable_identifier(ast, identifier_node),
                              parse_expression(ast, expression_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown assignment");
    return NULL;
  }
}

static inline TQLStatement *parse_statement(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "selector") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_statement_selector_new(ast, parse_selector(ast, inner_node));
  } else if (strcmp(node_type, "assignment") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_statement_assignment_new(ast,
                                        parse_tql_assignment(ast, inner_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown statement");
    return NULL;
  }
}

static inline TQLFunction *parse_function(TQLAst *ast, TSNode node) {
  TSNode identifier_node =
      ts_node_child_by_field_name(node, "identifier", strlen("identifier"));
  assert(!ts_node_is_null(identifier_node));
  uint32_t named_child_count = ts_node_named_child_count(node);
  uint32_t parameter_count = 0;
  uint32_t statement_count = 0;

  TQLVariableIdentifier *parameters[named_child_count];
  TQLStatement *statements[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(node); i++) {
    TSNode child_node = ts_node_named_child(node, i);
    const char *field_name = ts_node_field_name_for_named_child(node, i);
    if (strcmp(field_name, "parameters") == 0) {
      parameters[parameter_count++] = parse_identifier(ast, child_node);
    } else if (strcmp(field_name, "statement") == 0) {
      statements[statement_count++] = parse_statement(ast, child_node);
    }
  }

  return tql_function_new(ast, parse_identifier(ast, identifier_node),
                          parameters, parameter_count, statements,
                          statement_count);
}

static inline TQLSelector *parse_selector(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "self_selector") == 0) {
    return tql_selector_self_new(ast);
  } else if (strcmp(node_type, "node_type_selector") == 0) {
    return tql_selector_nodetype_new(ast, parse_identifier(ast, node));
  } else if (strcmp(node_type, "field_name_selector") == 0) {
    TSNode parent_node =
        ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TSNode field_node =
        ts_node_child_by_field_name(node, "field", strlen("field"));
    assert(!ts_node_is_null(field_node));

    return tql_selector_fieldname_new(
        ast,
        ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
        parse_identifier(ast, field_node));
  } else if (strcmp(node_type, "child_selector") == 0) {
    TSNode parent_node =
        ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TSNode child_node =
        ts_node_child_by_field_name(node, "child", strlen("child"));
    assert(!ts_node_is_null(child_node));

    return tql_selector_child_new(
        ast,
        ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
        parse_selector(ast, child_node));
    return NULL;
  } else if (strcmp(node_type, "descendant_selector") == 0) {
    TSNode parent_node =
        ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TSNode child_node =
        ts_node_child_by_field_name(node, "descendant", strlen("descendant"));
    assert(!ts_node_is_null(child_node));

    return tql_selector_descendant_new(
        ast,
        ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
        parse_selector(ast, child_node));
  } else if (strcmp(node_type, "block_selector") == 0) {
    TSNode parent_node =
        ts_node_child_by_field_name(node, "parent", strlen("parent"));

    uint32_t named_child_count = ts_node_named_child_count(node);
    uint32_t statement_count = 0;
    TQLStatement *statements[named_child_count];
    for (int i = 0; i < named_child_count; i++) {
      TSNode statement_node = ts_node_named_child(node, i);
      if (strcmp(ts_node_field_name_for_named_child(node, i), "statement") ==
          0) {
        statements[statement_count++] = parse_statement(ast, statement_node);
      }
    }
    return tql_selector_block_new(
        ast,
        ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
        statements, statement_count);
  } else if (strcmp(node_type, "variable_identifier") == 0) {
    return tql_selector_varid_new(ast, parse_variable_identifier(ast, node));
  } else if (strcmp(node_type, "function_invocation") == 0) {
    TSNode identifier_node =
        ts_node_child_by_field_name(node, "identifier", strlen("identifier"));
    uint32_t named_child_count = ts_node_named_child_count(node);
    uint32_t expr_count = 0;
    TQLExpression *exprs[named_child_count];
    for (int i = 0; i < named_child_count; i++) {
      TSNode expr_node = ts_node_named_child(node, i);
      if (strcmp(ts_node_field_name_for_named_child(node, i), "parameters") ==
          0) {
        TQLExpression *expr = parse_expression(ast, expr_node);
        exprs[expr_count++] = expr;
      }
    }
    return tql_selector_function_invocation_new(
        ast, parse_identifier(ast, identifier_node), exprs, expr_count);
  } else if (strcmp(node_type, "negate_selector") == 0) {
    TSNode selector_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(selector_node));
    return tql_selector_negate(ast, parse_selector(ast, selector_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown selector");
    return NULL;
  }
}

static inline TQLDirective *parse_directive(TQLAst *ast, TSNode node) {
  node = ts_node_named_child(node, 0);
  assert(!ts_node_is_null(node));
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "target_lang_directive") == 0) {
    TSNode language_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(language_node));
    return tql_directive_target(ast, parse_string_literal(ast, language_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Not implemented");
    return NULL;
  }
}

TQLAst *tql_parser_parse_string(TQLParser *parser, const char *string,
                                uint32_t length) {
  TSTree *ts_tree =
      ts_parser_parse_string(parser->ts_parser, NULL, string, length);
  TQLAst *ast = tql_ast_new(string, length);

  TSNode root_node = ts_tree_root_node(ts_tree);
  uint32_t named_child_count = ts_node_named_child_count(root_node);
  uint32_t function_count = 0;
  uint32_t directive_count = 0;
  TQLFunction *functions[named_child_count];
  TQLDirective *directives[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(root_node); i++) {
    TSNode toplevel_node = ts_node_named_child(root_node, i);
    assert(!ts_node_is_null(toplevel_node));
    // TODO: Parse directives
    if (strcmp(ts_node_type(toplevel_node), "function_definition") == 0) {
      functions[function_count++] = parse_function(ast, toplevel_node);
    } else if (strcmp(ts_node_type(toplevel_node), "directive") == 0) {
      directives[directive_count++] = parse_directive(ast, toplevel_node);
    } else {
      assert(false && "Unknown toplevel");
    }
  }

  ast->tree = tql_tree_new(ast, functions, function_count, directives, directive_count);
  ts_tree_delete(ts_tree);
  return ast;
}

void tql_parser_free(TQLParser *parser) {
  ts_parser_delete(parser->ts_parser);
  parser->ts_parser = NULL;
  free(parser);
}
