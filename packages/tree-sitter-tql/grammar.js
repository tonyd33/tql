/**
 * @file TQL (Tree Query Language)
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  union: 1,
  pipe: 2,
  or: 3,
  and: 4,
  not: 5,
  cmp: 6,
  add: 7,
  mul: 8,
  app: 9,
  field: 10,
};

module.exports = grammar({
  name: "tql",

  extras: $ => [/\s/, $.comment],

  word: $ => $.identifier,

  rules: {
    source_file: $ => repeat($._declaration),

    comment: _ => token(seq("--", /.*/)),

    _declaration: $ => choice($.signature, $.definition),

    signature: $ =>
      seq(field("name", $.identifier), ":", field("type", $._type), ";"),

    definition: $ =>
      seq(
        field("name", $.identifier),
        repeat(field("parameter", $.identifier)),
        "=",
        field("body", $._expression),
        ";",
      ),

    _expression: $ =>
      choice(
        $.union,
        $.pipe,
        $.logical_or,
        $.logical_and,
        $.logical_not,
        $.comparison,
        $.additive,
        $.multiplicative,
        $.application,
        $.field_access,
        $._primary,
      ),

    union: $ =>
      prec.left(
        PREC.union,
        seq(field("left", $._expression), ",", field("right", $._expression)),
      ),

    pipe: $ =>
      prec.left(
        PREC.pipe,
        seq(field("left", $._expression), "|", field("right", $._expression)),
      ),

    logical_or: $ =>
      prec.left(
        PREC.or,
        seq(field("left", $._expression), "or", field("right", $._expression)),
      ),

    logical_and: $ =>
      prec.left(
        PREC.and,
        seq(field("left", $._expression), "and", field("right", $._expression)),
      ),

    logical_not: $ =>
      prec.right(PREC.not, seq("not", field("operand", $._expression))),

    comparison: $ =>
      prec.left(
        PREC.cmp,
        seq(
          field("left", $._expression),
          field("operator", choice("=", "!=", "<", "<=", ">", ">=", "~", "!~")),
          field("right", $._expression),
        ),
      ),

    additive: $ =>
      prec.left(
        PREC.add,
        seq(
          field("left", $._expression),
          field("operator", choice("+", "-")),
          field("right", $._expression),
        ),
      ),

    multiplicative: $ =>
      prec.left(
        PREC.mul,
        seq(
          field("left", $._expression),
          field("operator", choice("*", "/", "%")),
          field("right", $._expression),
        ),
      ),

    application: $ =>
      prec.left(
        PREC.app,
        seq(field("function", $._expression), field("argument", $._expression)),
      ),

    field_access: $ =>
      prec.left(
        PREC.field,
        seq(
          field("record", $._expression),
          token.immediate("."),
          field("field", $.field_name),
        ),
      ),

    field_name: _ => token.immediate(/[a-z_][a-zA-Z0-9_]*/),

    // A leading `.` is `identity` unless a name follows it immediately.
    leading_field: $ => seq(".", field("field", $.field_name)),

    let_expression: $ =>
      prec.right(
        seq(
          "let",
          field("bindings", $.binding_group),
          "in",
          field("body", $._expression),
        ),
      ),

    binding_group: $ => seq("{", sep_trailing($.binding, ";"), "}"),

    binding: $ =>
      seq(
        field("name", $.identifier),
        repeat(field("parameter", $.identifier)),
        "=",
        field("value", $._expression),
      ),

    do_expression: $ => seq("do", "{", optional($._do_items), "}"),

    _do_items: $ =>
      seq(
        repeat(seq($._do_statement, ";")),
        field("result", $._expression),
        optional(";"),
      ),

    _do_statement: $ => choice($.bind_statement, $.let_statement),

    bind_statement: $ =>
      seq(field("name", $.identifier), "<-", field("value", $._expression)),

    let_statement: $ =>
      seq("let", field("bindings", choice($.binding, $.binding_group))),

    if_expression: $ =>
      prec.right(
        seq(
          "if",
          field("condition", $._expression),
          "then",
          field("consequence", $._expression),
          "else",
          field("alternative", $._expression),
        ),
      ),

    lambda: $ =>
      prec.right(
        seq(
          "\\",
          repeat1(field("parameter", $.identifier)),
          "->",
          field("body", $._expression),
        ),
      ),

    _primary: $ =>
      choice(
        $.identity,
        $.leading_field,
        $.kind,
        $.identifier,
        $.number,
        $.string,
        $.boolean,
        $.regex,
        $.list,
        $.record,
        $.parenthesized,
        $.lambda,
        $.let_expression,
        $.do_expression,
        $.if_expression,
      ),

    identity: _ => ".",

    kind: _ => token(seq(":", /[a-zA-Z_][a-zA-Z0-9_]*/)),

    parenthesized: $ => seq("(", $._expression, ")"),

    // One expression, not a separated list: `,` inside the brackets is stream
    // union, so `[a, b]` collects the union and yields a single list.
    list: $ => seq("[", optional($._expression), "]"),

    record: $ => seq("{", optional(sep_trailing($.record_field, ",")), "}"),

    record_field: $ =>
      prec(
        PREC.union + 1,
        seq(field("name", $.identifier), "=", field("value", $._expression)),
      ),

    _type: $ => choice($.function_type, $._type_atom),

    function_type: $ =>
      prec.right(seq(field("from", $._type_atom), "->", field("to", $._type))),

    _type_atom: $ =>
      choice(
        $.filter_type,
        $.list_type,
        $.record_type,
        $.type_identifier,
        $.type_variable,
        $.parenthesized_type,
      ),

    filter_type: $ =>
      seq(
        "Filter",
        field("input", $._type_operand),
        field("output", $._type_operand),
      ),

    _type_operand: $ =>
      choice(
        $.list_type,
        $.record_type,
        $.type_identifier,
        $.type_variable,
        $.parenthesized_type,
      ),

    list_type: $ => seq("[", $._type, "]"),

    record_type: $ =>
      seq("{", optional(sep_trailing($.record_type_field, ",")), "}"),

    record_type_field: $ =>
      seq(field("name", $.identifier), ":", field("type", $._type)),

    parenthesized_type: $ => seq("(", $._type, ")"),

    type_identifier: _ => /[A-Z][a-zA-Z0-9_]*/,

    type_variable: _ => /[a-z][a-zA-Z0-9_]*/,

    identifier: _ => /[a-z_][a-zA-Z0-9_]*/,

    number: _ => token(seq(optional("-"), /[0-9]+/)),

    string: _ => token(seq('"', repeat(choice(/[^"\\]/, seq("\\", /./))), '"')),

    boolean: _ => choice("true", "false"),

    regex: _ => token(seq('r"', repeat(choice(/[^"\\]/, seq("\\", /./))), '"')),
  },
});

/**
 * One or more `rule`, separated by `sep`, with an optional trailing `sep`.
 * @param {RuleOrLiteral} rule
 * @param {RuleOrLiteral} sep
 */
function sep_trailing(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)), optional(sep));
}
