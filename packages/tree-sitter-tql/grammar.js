/**
 * @file TQL (Tree Query Language)
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  child: 19,
  descendant: 18,
  field: 17,

  pipe: 11,
  comparison: 9,
  not: 8,
  and: 7,
  or: 6,
  bind: 3,
  union: 2,
};

module.exports = grammar({
  name: "tql",

  extras: $ => [/\s/, $.comment],

  rules: {
    source_file: $ =>
      repeat(choice($.directive, $.function_definition, $.expression)),

    comment: _ => token(seq("--", /.*/)),

    // Directives
    directive: $ => seq("#", choice($.language_directive, $.import_directive)),

    language_directive: $ =>
      seq("language", field("language", $.string_literal)),

    import_directive: $ => seq("import", field("path", $.string_literal)),

    // Function definitions: def name(@a; @b): expr;
    function_definition: $ =>
      seq(
        "def",
        field("name", $.identifier),
        optional(field("parameters", $.def_parameters)),
        ":",
        field("body", $.expression),
        ";",
      ),

    def_parameters: $ => seq("(", optional(semicolon_sep1($.variable)), ")"),

    expression: $ =>
      choice(
        $.identity,
        $.dot_field_access,
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
        $.collect_expression,
        $.tuple_literal,
        $.parenthesized,
        $.bind_expression,
        $.pipe_expression,
        $.union_expression,
        $.comparison,
        $.is_null_expr,
        $.logical_and,
        $.logical_or,
        $.logical_not,
      ),

    bind_expression: $ =>
      prec.right(
        PREC.bind,
        seq(
          field("expression", $.expression),
          "as",
          field("variable", $.variable),
          optional(field("optional", "?")),
        ),
      ),

    pipe_expression: $ =>
      prec.left(
        PREC.pipe,
        seq(field("left", $.expression), "|", field("right", $.expression)),
      ),

    union_expression: $ =>
      prec.left(
        PREC.union,
        seq(field("left", $.expression), "<|>", field("right", $.expression)),
      ),

    identity: _ => token("."),

    // TODO: Get rid of this
    dot_field_access: $ =>
      prec.left(PREC.field, seq(".", field("field", $.identifier))),

    node_selector: $ => prec(-1, $.identifier),

    field_access: $ =>
      prec.left(
        PREC.field,
        seq(field("base", $.expression), ".", field("field", $.identifier)),
      ),

    child_navigation: $ =>
      prec.left(
        PREC.child,
        seq(
          field("parent", $.expression),
          "/",
          field("child", $.node_selector),
        ),
      ),

    descendant_navigation: $ =>
      prec.left(
        PREC.descendant,
        seq(
          field("parent", $.expression),
          "//",
          field("descendant", $.node_selector),
        ),
      ),

    is_null_expr: $ =>
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
          field("operator", choice("=", "!=", "~", "!~")),
          field("right", $.expression),
        ),
      ),

    logical_and: $ =>
      prec.left(
        PREC.and,
        seq(field("left", $.expression), "and", field("right", $.expression)),
      ),

    logical_or: $ =>
      prec.left(
        PREC.or,
        seq(field("left", $.expression), "or", field("right", $.expression)),
      ),

    logical_not: $ =>
      prec.right(PREC.not, seq("not", field("predicate", $.expression))),

    function_call: $ =>
      choice(
        prec(
          1,
          seq(
            field("name", $.identifier),
            "(",
            optional(semicolon_sep1(field("argument", $.expression))),
            ")",
          ),
        ),
        field("name", $.identifier),
      ),

    object_literal: $ => seq("{", optional(comma_sep1($.object_field)), "}"),

    object_field: $ =>
      choice(
        $.variable,
        seq(field("key", $.identifier), ":", field("value", $.expression)),
      ),

    array_literal: $ => seq("[", optional(comma_sep1($.expression)), "]"),

    collect_expression: $ => prec(1, seq("[", $.expression, "]")),

    tuple_literal: $ =>
      seq("(", $.expression, ",", comma_sep1($.expression), ")"),

    parenthesized: $ => seq("(", $.expression, ")"),

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

function semicolon_sep1(rule) {
  return seq(rule, repeat(seq(";", rule)));
}
