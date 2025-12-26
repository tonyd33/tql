#include "parser.h"
#include <stdio.h>

#define assert_node_type(node, node_type)                                      \
  assert(ts_node_symbol((node)) ==                                             \
         ts_language_symbol_for_name(tree_sitter_tql(), (node_type),           \
                                     strlen((node_type)), true))

/* TODO: Use symbol ids/field ids */

const TSLanguage *tree_sitter_tql(void);

static TQLSelector *parse_selector(TQLAst *ast, TSNode node);
static TQLStatement *parse_statement(TQLAst *ast, TSNode node);
static TQLCondition *parse_condition(TQLAst *ast, TSNode node);

void tql_parser_init(TQLParser *parser) {
  parser->ts_parser = ts_parser_new();
  ts_parser_set_language(parser->ts_parser, tree_sitter_tql());
}

static TQLVariableIdentifier *parse_variable_identifier(TQLAst *ast,
                                                        TSNode node) {
  uint32_t start_byte = ts_node_start_byte(node);
  uint32_t end_byte = ts_node_end_byte(node);
  return tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);
}

static TQLExpression *parse_expression(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "selector") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_expression_new(ast, parse_selector(ast, inner_node));
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

static TQLCondition *parse_condition(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "empty_condition") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_condition_empty_new(ast, parse_expression(ast, inner_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown condition");
    return NULL;
  }
}

static TQLStatement *parse_statement(TQLAst *ast, TSNode node) {
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
  } else if (strcmp(node_type, "condition") == 0) {
    TSNode inner_node = ts_node_named_child(node, 0);
    assert(!ts_node_is_null(inner_node));
    return tql_statement_condition_new(ast, parse_condition(ast, inner_node));
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown statement");
    return NULL;
  }
}

static TQLSelector *parse_selector(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "universal_selector") == 0) {
    return tql_selector_universal_new(ast);
  } else if (strcmp(node_type, "self_selector") == 0) {
    return tql_selector_self_new(ast);
  } else if (strcmp(node_type, "node_type_selector") == 0) {
    uint32_t start_byte = ts_node_start_byte(node);
    uint32_t end_byte = ts_node_end_byte(node);
    TQLVariableIdentifier *node_type =
        tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);
    return tql_selector_nodetype_new(ast, node_type);
  } else if (strcmp(node_type, "field_name_selector") == 0) {
    TSNode parent_node =
        ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TQLSelector *parent_selector =
        ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node);
    TSNode field_node =
        ts_node_child_by_field_name(node, "field", strlen("field"));
    assert(!ts_node_is_null(field_node));

    uint32_t start_byte = ts_node_start_byte(field_node);
    uint32_t end_byte = ts_node_end_byte(field_node);
    TQLVariableIdentifier *field =
        tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);

    return tql_selector_fieldname_new(ast, parent_selector, field);
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
        ts_node_child_by_field_name(node, "child", strlen("child"));
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
    for (int i = 0; i < ts_node_named_child_count(node); i++) {
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
  } else {
    fprintf(stderr, "Got node type %s\n", node_type);
    assert(false && "Unknown selector");
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
  uint32_t selector_count = 0;
  TQLSelector *selectors[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(root_node); i++) {
    TSNode selector_node = ts_node_named_child(root_node, i);
    selectors[selector_count++] = parse_selector(ast, selector_node);
  }

  ast->tree = tql_tree_new(ast, selectors, selector_count);
  ts_tree_delete(ts_tree);
  return ast;
}

void tql_parser_free(TQLParser *parser) {
  ts_parser_delete(parser->ts_parser);
  parser->ts_parser = NULL;
}
