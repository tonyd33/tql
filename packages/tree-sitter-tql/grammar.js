/**
 * @file TQL (Tree Query Language) - Option B Grammar
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  child: 19,
  descendant: 18,
  field: 17,

  not: 10,
  and: 9,
  or: 8,

  comparison: 7,
};

module.exports = grammar({
  name: "tql",

  extras: $ => [/\s/, $.comment],

  rules: {
    source_file: $ =>
      repeat(choice($.directive, $.query_definition, $.query_body)),

    comment: _ => token(seq("--", /.*/)),

    // Directives
    directive: $ => seq("#", choice($.language_directive, $.import_directive)),

    language_directive: $ =>
      seq("language", field("language", $.string_literal)),

    import_directive: $ => seq("import", field("path", $.string_literal)),

    // Query definitions
    query_definition: $ =>
      seq(
        "query",
        field("name", $.identifier),
        optional($.parameters),
        optional($.return_type_annotation),
        "{",
        field("body", $.query_body),
        "}",
      ),

    parameters: $ => seq("(", optional(comma_sep1($.parameter)), ")"),

    parameter: $ =>
      seq(field("name", $.variable), optional(seq(":", field("type", $.type)))),

    return_type_annotation: $ => seq(":", field("type", $.type)),

    query_body: $ =>
      seq(
        optional(field("with_clause", $.with_clause)),
        optional(field("where_clause", $.where_clause)),
        field("select_clause", $.select_clause),
      ),

    with_clause: $ => seq("with", comma_sep1($.binding)),

    binding: $ =>
      seq(
        field("expression", $.expression),
        "as",
        field("variable", $.variable),
        optional(field("optional", "?")),
      ),

    node_selector: $ => $.identifier,

    field_access: $ =>
      prec.left(
        PREC.field,
        seq(field("base", $.expression), ".", field("field", $.identifier)),
      ),

    child_navigation: $ =>
      prec.left(
        PREC.child,
        seq(field("parent", $.expression), ">", field("child", $.expression)),
      ),

    descendant_navigation: $ =>
      prec.left(
        PREC.descendant,
        seq(
          field("parent", $.expression),
          choice("descendant::", ">>"),
          field("descendant", $.expression),
        ),
      ),

    parenthesized_expression: $ => seq("(", $.expression, ")"),

    where_clause: $ => seq("where", field("predicate", $.predicate)),

    predicate: $ =>
      choice(
        $.comparison,
        $.is_null_predicate,
        $.logical_and,
        $.logical_or,
        $.logical_not,
        $.quantified_expression,
        $.parenthesized_predicate,
      ),

    is_null_predicate: $ =>
      prec.left(
        PREC.comparison,
        seq(
          field("expression", $.expression),
          "is",
          field("negated", optional("not")),
          $.null_literal,
        ),
      ),

    comparison: $ =>
      prec.left(
        PREC.comparison,
        seq(
          field("left", $.expression),
          // maybe these should have first class distinction to support syntax
          // like 'foo' not like /regex/ or @bar is not null
          field("operator", choice("=", "!=", "~", "!~", ">", "<", ">=", "<=")),
          field("right", $.expression),
        ),
      ),

    logical_and: $ =>
      prec.left(
        PREC.and,
        seq(field("left", $.predicate), "and", field("right", $.predicate)),
      ),

    logical_or: $ =>
      prec.left(
        PREC.or,
        seq(field("left", $.predicate), "or", field("right", $.predicate)),
      ),

    logical_not: $ =>
      prec.right(PREC.not, seq("not", field("predicate", $.predicate))),

    quantified_expression: $ =>
      seq(
        field("quantifier", choice("any", "all")),
        field("variable", $.variable),
        "in",
        field("source", $.expression),
        ":",
        field("predicate", $.predicate),
      ),

    parenthesized_predicate: $ => seq("(", $.predicate, ")"),

    select_clause: $ => seq("select", field("projection", $.projection)),

    projection: $ => $.expression,

    object_literal: $ => seq("{", optional(comma_sep1($.object_field)), "}"),

    object_field: $ =>
      choice(
        // Shorthand: @variable
        $.variable,
        // Full form: field: expression
        seq(field("key", $.identifier), ":", field("value", $.expression)),
      ),

    array_literal: $ => seq("[", optional(comma_sep1($.expression)), "]"),

    tuple_literal: $ =>
      seq("(", $.expression, ",", comma_sep1($.expression), ")"),

    subquery: $ => seq("(", $.query_body, ")"),

    // Expressions
    expression: $ =>
      choice(
        $.node_selector,
        $.variable,
        $.string_literal,
        $.regex_literal,
        $.number_literal,
        $.null_literal,
        $.field_access,
        $.child_navigation,
        $.descendant_navigation,
        $.function_call,
        $.object_literal,
        $.array_literal,
        $.tuple_literal,
        $.subquery,
        $.parenthesized_expression,
      ),

    function_call: $ =>
      seq(
        field("name", $.identifier),
        "(",
        optional(comma_sep1(field("argument", $.expression))),
        ")",
      ),

    // Types
    type: $ =>
      choice(
        $.identifier,
        $.builtin_type,
        $.array_type,
        $.object_type,
        $.tuple_type,
        $.optional_type,
      ),

    builtin_type: _ => choice("string", "number", "boolean", "regex"),

    array_type: $ => seq("Array", "<", field("element_type", $.type), ">"),

    object_type: $ => seq("Object", "<", field("value_type", $.type), ">"),

    tuple_type: $ =>
      seq("Tuple", "<", comma_sep1(field("element_type", $.type)), ">"),

    optional_type: $ => seq(field("base_type", $.type), "?"),

    // Literals
    string_literal: $ =>
      seq(
        "'",
        field(
          "content",
          optional(repeat(choice($.string_fragment, $.escape_sequence))),
        ),
        "'",
      ),

    string_fragment: _ => token.immediate(prec(1, /[^'\\]+/)),

    escape_sequence: _ =>
      token.immediate(
        seq(
          "\\",
          choice(
            /[^xu0-7]/,
            /[0-7]{1,3}/,
            /x[0-9a-fA-F]{2}/,
            /u[0-9a-fA-F]{4}/,
            /u\{[0-9a-fA-F]+\}/,
          ),
        ),
      ),

    regex_literal: $ =>
      seq(
        "/",
        field(
          "pattern",
          optional(repeat(choice($.regex_fragment, $.regex_escape_sequence))),
        ),
        "/",
      ),

    regex_fragment: _ => token.immediate(prec(1, /[^/\\]+/)),

    regex_escape_sequence: _ => token.immediate(seq("\\", /./)),

    number_literal: _ => /\d+?/,

    null_literal: _ => "null",

    // Identifiers
    variable: $ => seq("@", $.identifier),

    identifier: _ => /[a-zA-Z_][a-zA-Z0-9_]*/,
  },
});

function comma_sep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}
