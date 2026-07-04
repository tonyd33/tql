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
      repeat(choice($.directive, $.function_definition, $.pipeline)),

    comment: _ => token(seq("--", /.*/)),

    // Directives
    directive: $ => seq("#", choice($.language_directive, $.import_directive)),

    language_directive: $ =>
      seq("language", field("language", $.string_literal)),

    import_directive: $ => seq("import", field("path", $.string_literal)),

    // Function definitions: def name(@a; @b): pipeline;
    function_definition: $ =>
      seq(
        "def",
        field("name", $.identifier),
        optional(field("parameters", $.def_parameters)),
        ":",
        field("body", $.pipeline),
        ";",
      ),

    def_parameters: $ => seq("(", optional(semicolon_sep1($.variable)), ")"),

    // Pipeline: step | step | ... | step
    pipeline: $ => seq($.pipeline_step, repeat(seq("|", $.pipeline_step))),

    pipeline_step: $ => choice($.bind_step, $.select_step, $.expression),

    // expr as @v  or  expr as @v?
    bind_step: $ =>
      seq(
        field("expression", $.expression),
        "as",
        field("variable", $.variable),
        optional(field("optional", "?")),
      ),

    // select(pred)
    select_step: $ => seq("select", "(", field("predicate", $.predicate), ")"),

    // Navigation expressions
    node_selector: $ => prec(-1, $.identifier),

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
          ">>",
          field("descendant", $.expression),
        ),
      ),

    // Predicates
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

    // any(gen; cond) / all(gen; cond)
    quantified_expression: $ =>
      seq(
        field("quantifier", choice("any", "all")),
        "(",
        field("source", $.expression),
        ";",
        field("predicate", $.predicate),
        ")",
      ),

    parenthesized_predicate: $ => seq("(", $.predicate, ")"),

    // Expressions
    expression: $ =>
      choice(
        $.dot_field_access,
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
        $.array_collect,
        $.tuple_literal,
        $.subquery,
      ),

    dot_field_access: $ =>
      prec.left(PREC.field, seq(".", field("field", $.identifier))),

    function_call: $ =>
      seq(
        field("name", $.identifier),
        "(",
        optional(semicolon_sep1(field("argument", $.expression))),
        ")",
      ),

    object_literal: $ => seq("{", optional(comma_sep1($.object_field)), "}"),

    object_field: $ =>
      choice(
        $.variable,
        seq(field("key", $.identifier), ":", field("value", $.expression)),
      ),

    array_literal: $ => seq("[", optional(comma_sep1($.expression)), "]"),

    array_collect: $ =>
      seq(
        "[",
        choice(
          seq($.bind_step, repeat(seq("|", $.pipeline_step))),
          seq($.select_step, repeat(seq("|", $.pipeline_step))),
          seq(
            $.expression,
            "|",
            $.pipeline_step,
            repeat(seq("|", $.pipeline_step)),
          ),
        ),
        "]",
      ),

    tuple_literal: $ =>
      seq("(", $.expression, ",", comma_sep1($.expression), ")"),

    subquery: $ => seq("(", $.pipeline, ")"),

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

function semicolon_sep1(rule) {
  return seq(rule, repeat(seq(";", rule)));
}
