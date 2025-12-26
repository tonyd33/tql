#include <stdio.h>
#include "parser.h"

#define assert_node_type(node, node_type) \
  assert(ts_node_symbol((node)) == ts_language_symbol_for_name(tree_sitter_tql(), (node_type), strlen((node_type)), true))

/* TODO: Use symbol ids/field ids */

const TSLanguage *tree_sitter_tql(void);

static TQLQuery *parse_query(TQLAst *ast, TSNode node);
static TQLPureSelector *parse_pure_selector(TQLAst *ast, TSNode node);
static TQLInlineNodeOperation *parse_inline_statement(TQLAst *ast, TSNode node);
static TQLSelector *parse_selector(TQLAst *ast, TSNode node);
static TQLStatement *parse_statement(TQLAst *ast, TSNode node);

void tql_parser_init(TQLParser *parser) {
  parser->ts_parser = ts_parser_new();
  ts_parser_set_language(parser->ts_parser, tree_sitter_tql());
}

static TQLStatement *parse_statement(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "query") == 0) {
    return tql_statement_query_new(ast, parse_query(ast, node));
  } else if (strcmp(node_type, "assignment") == 0) {
    assert(false && "Not implemented");
    return NULL;
  } else if (strcmp(node_type, "condition") == 0) {
    assert(false && "Not implemented");
    return NULL;
  }
  return NULL;
}

static TQLPureSelector *parse_pure_selector(TQLAst *ast, TSNode node) {
  const char *node_type = ts_node_type(node);
  if (strcmp(node_type, "universal_selector") == 0) {
    return tql_pure_selector_universal_new(ast);
  } else if (strcmp(node_type, "node_type_selector") == 0) {
    uint32_t start_byte = ts_node_start_byte(node);
    uint32_t end_byte = ts_node_end_byte(node);
    TQLVariableIdentifier *node_type = tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);
    return tql_pure_selector_nodetype_new(ast, node_type);
  } else if (strcmp(node_type, "field_name_selector") == 0) {
    TSNode parent_node = ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TQLSelector *parent_selector =
      ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node);
    TSNode field_node = ts_node_child_by_field_name(node, "field", strlen("field"));
    assert(!ts_node_is_null(field_node));

    uint32_t start_byte = ts_node_start_byte(field_node);
    uint32_t end_byte = ts_node_end_byte(field_node);
    TQLVariableIdentifier *field = tql_string_new(ast, ast->source + start_byte, end_byte - start_byte);

    return tql_pure_selector_fieldname_new(ast, parent_selector, field);
  } else if (strcmp(node_type, "child_selector") == 0) {
    TSNode parent_node = ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TSNode child_node = ts_node_child_by_field_name(node, "child", strlen("child"));
    assert(!ts_node_is_null(child_node));

    return tql_pure_selector_child_new(
      ast,
      ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
      parse_selector(ast, child_node)
    );
    return NULL;
  } else if (strcmp(node_type, "descendant_selector") == 0) {
    TSNode parent_node = ts_node_child_by_field_name(node, "parent", strlen("parent"));
    TSNode child_node = ts_node_child_by_field_name(node, "child", strlen("child"));
    assert(!ts_node_is_null(child_node));

    return tql_pure_selector_descendant_new(
      ast,
      ts_node_is_null(parent_node) ? NULL : parse_selector(ast, parent_node),
      parse_selector(ast, child_node)
    );
  } else if (strcmp(node_type, "variable_identifier") == 0) {
    assert(false && "Not implemented");
    return NULL;
  } else {
    assert(false && "Unknown selector");
    return NULL;
  }
}

static TQLInlineNodeOperation *parse_inline_statement(TQLAst *ast, TSNode node) {
  assert(false && "Not implemented");
  return NULL;
}

static TQLSelector *parse_selector(TQLAst *ast, TSNode node) {
  TSNode pure_selector_node = ts_node_child_by_field_name(node, "pure_selector", strlen("pure_selector"));
  assert(!ts_node_is_null(pure_selector_node));
  TQLPureSelector *pure_selector = parse_pure_selector(ast, pure_selector_node);

  uint32_t named_child_count = ts_node_named_child_count(node);
  uint32_t statement_count = 0;
  TQLInlineNodeOperation *statements[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(node); i++) {
    const char *field_name = ts_node_field_name_for_named_child(node, i);
    if (strcmp(field_name, "statement") == 0) {
      TSNode statement_node = ts_node_named_child(node, i);
      statements[statement_count++] = parse_inline_statement(ast, statement_node);
    }
  }

  return tql_selector_new(ast, pure_selector, statements, statement_count);
}

static TQLQuery *parse_query(TQLAst *ast, TSNode node) {
  assert_node_type(node, "query");
  TSNode selector_node = ts_node_child_by_field_name(node, "selector", strlen("selector"));
  assert(!ts_node_is_null(selector_node));
  TQLSelector *selector = parse_selector(ast, selector_node);

  uint32_t named_child_count = ts_node_named_child_count(node);
  uint32_t statement_count = 0;
  TQLStatement *statements[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(node); i++) {
    const char *field_name = ts_node_field_name_for_named_child(node, i);
    if (strcmp(field_name, "statement") == 0) {
      TSNode statement_node = ts_node_named_child(node, i);
      statements[statement_count++] = parse_statement(ast, statement_node);
    }
  }
  TQLQuery *query = tql_query_new(ast, selector, statements, statement_count);
  return query;
}

TQLAst *tql_parser_parse_string(TQLParser *parser, const char *string, uint32_t length) {
  TSTree *ts_tree = ts_parser_parse_string(parser->ts_parser, NULL, string, length);
  TQLAst *ast = tql_ast_new(string, length);

  TSNode root_node = ts_tree_root_node(ts_tree);
  uint32_t named_child_count = ts_node_named_child_count(root_node);
  uint32_t query_count = 0;
  TQLQuery *queries[named_child_count];
  for (int i = 0; i < ts_node_named_child_count(root_node); i++) {
    TSNode query_node = ts_node_named_child(root_node, i);
    const char *node_type = ts_node_type(query_node);
    if (strcmp(node_type, "query") == 0) {
      queries[query_count++] = parse_query(ast, query_node);
    } else {
      printf("Got node type %s\n", node_type);
    }
  }

  ast->tree = tql_tree_new(ast, queries, query_count);
  ts_tree_delete(ts_tree);
  return ast;
}

void tql_parser_free(TQLParser *parser) {
  ts_parser_delete(parser->ts_parser);
  parser->ts_parser = NULL;
}
