#include "parser.h"
#include <stdio.h>

#define assert_node_type(node, node_type)                                      \
  assert(ts_node_symbol((node)) ==                                             \
         ts_language_symbol_for_name(tree_sitter_tql(), (node_type),           \
                                     strlen((node_type)), true))

/* TODO: Use symbol ids/field ids */

const TSLanguage *tree_sitter_tql(void);

static inline TQLSelector *parse_selector(TQLAst *ast, TSNode node);
static inline TQLStatement *parse_statement(TQLAst *ast, TSNode node);
static inline TQLSelector *parse_function(TQLAst *ast, TSNode node);
// static TQLCondition *parse_condition(TQLAst *ast, TSNode node);

void tql_parser_init(TQLParser *parser) {
  parser->ts_parser = ts_parser_new();
  ts_parser_set_language(parser->ts_parser, tree_sitter_tql());
}

static TQLString *parse_identifier(TQLAst *ast, TSNode node) {
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

// static TQLCondition *parse_condition(TQLAst *ast, TSNode node) {
//   const char *node_type = ts_node_type(node);
//   if (strcmp(node_type, "empty_condition") == 0) {
//     TSNode inner_node = ts_node_named_child(node, 0);
//     assert(!ts_node_is_null(inner_node));
//     return tql_condition_empty_new(ast, parse_expression(ast, inner_node));
//   } else if (strcmp(node_type, "text_eq_condition") == 0) {
//     TSNode expression_node = ts_node_named_child(node, 0);
//     TSNode string_node = ts_node_named_child(node, 1);
//     assert(!ts_node_is_null(expression_node));
//     assert(!ts_node_is_null(string_node));
//
//     return tql_condition_texteq_new(ast, parse_expression(ast,
//     expression_node),
//                                     parse_string_literal(ast, string_node));
//     return NULL;
//   } else if (strcmp(node_type, "and_condition") == 0) {
//     TSNode c1_node = ts_node_named_child(node, 0);
//     TSNode c2_node = ts_node_named_child(node, 1);
//     assert(!ts_node_is_null(c1_node));
//     assert(!ts_node_is_null(c2_node));
//
//     return tql_condition_and_new(ast, parse_condition(ast, c1_node),
//                                  parse_condition(ast, c2_node));
//   } else {
//     fprintf(stderr, "Got node type %s\n", node_type);
//     assert(false && "Unknown condition");
//     return NULL;
//   }
// }

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
  uint32_t function_count = 0;
  TQLFunction *functions[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(root_node); i++) {
    TSNode function_node = ts_node_named_child(root_node, i);
    functions[function_count++] = parse_function(ast, function_node);
  }

  ast->tree = tql_tree_new(ast, selectors, selector_count);
  ts_tree_delete(ts_tree);
  return ast;
}

void tql_parser_free(TQLParser *parser) {
  ts_parser_delete(parser->ts_parser);
  parser->ts_parser = NULL;
}
