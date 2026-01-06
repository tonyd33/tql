/**
 * @file tree query language
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const alpha = /[a-zA-Z_]+/;
const alphanumeric = /[a-zA-Z0-9_]/;

module.exports = grammar({
  name: "tql",
  externals: $ => [$._descendant_operator],
  extras: $ => [/\s/, $.comment],
  reserved: {
    global: _ => [],
  },
  rules: {
    source_file: $ => repeat(choice($.directive, $.function_definition)),
    comment: _ => token(seq("--", /[^\r\n\u2028\u2029]*/)),
    identifier: _ => token(seq(alpha, repeat(alphanumeric))),

    string_literal: $ =>
      seq(
        "'",
        field(
          "content",
          repeat(
            choice(
              alias($.unescaped_single_string_fragment, $.string_fragment),
              $.escape_sequence,
            ),
          ),
        ),
        "'",
      ),
    unescaped_single_string_fragment: _ =>
      token.immediate(prec(1, /[^'\\\r\n]+/)),
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
            /[\r?][\n\u2028\u2029]/,
          ),
        ),
      ),

    variable_identifier: $ => seq("@", $.identifier),

    directive: $ =>
      seq("#", choice($.include_directive, $.target_lang_directive)),
    target_lang_directive: $ => seq("language", $.string_literal),
    include_directive: $ => seq("import", $.string_literal),

    function_definition: $ =>
      seq(
        "fn",
        field("identifier", $.identifier),
        parentheses_enclosed(
          comma_sep(field("parameters", $.variable_identifier)),
        ),
        braces_enclosed(
          seq(sep_by(";", field("statement", $._statement)), optional(";")),
        ),
      ),
    function_invocation: $ =>
      seq(
        field("identifier", $.identifier),
        parentheses_enclosed(comma_sep(field("parameters", $._expression))),
      ),

    _statement: $ =>
      choice(
        alias($._selector, $.selector),
        alias($._assignment, $.assignment),
      ),

    // selectors
    _selector: $ =>
      choice(
        $.parenthesized_selector,
        $.self_selector,
        $.node_type_selector,
        $.field_name_selector,
        $.child_selector,
        $.descendant_selector,
        $.block_selector,
        $.variable_identifier,
        $.function_invocation,
        $.negate_selector,
        $.and_selector,
        $.or_selector,
        $.condition_selector,
      ),
    selector: $ => $._selector,
    parenthesized_selector: $ => prec(100, parentheses_enclosed($._selector)),
    self_selector: _ => "*",
    node_type_selector: $ => alias($.identifier, $.node_type),
    field_name_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $._selector)),
          ".",
          field("field", alias($.identifier, $.field_name)),
        ),
      ),
    child_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $._selector)),
          ">",
          field("child", $._selector),
        ),
      ),
    descendant_selector: $ =>
      prec.left(
        seq(
          field("parent", $._selector),
          $._descendant_operator,
          field("descendant", $._selector),
        ),
      ),
    block_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $._selector)),
          braces_enclosed(
            seq(sep_by(";", field("statement", $._statement)), optional(";")),
          ),
        ),
      ),
    negate_selector: $ => prec.left(seq("!", $._selector)),
    and_selector: $ =>
      prec.left(
        seq(field("left", $._selector), "&&", field("right", $._selector)),
      ),
    or_selector: $ =>
      prec.left(
        seq(field("left", $._selector), "||", field("right", $._selector)),
      ),
    condition_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $._selector)),
          enclosed_by("[", "]", field("condition", $.condition)),
        ),
      ),

    relation: _ => choice("=", "~", "/="),
    condition: $ => seq($.expression, $.relation, $.expression),

    // assignments
    _assignment: $ => choice($.explicit_assignment),
    assignment: $ => $.assignment,
    explicit_assignment: $ =>
      seq(
        field("identifier", $.variable_identifier),
        "<-",
        field("expression", $._expression),
      ),

    // expressions
    _expression: $ => choice($.selector, $.string_literal),
    expression: $ => $._expression,
  },
});

function sep_by_1(s, rule) {
  return seq(rule, repeat(seq(s, rule)));
}

function sep_by(s, rule) {
  return optional(sep_by_1(s, rule));
}

function comma_sep_1(rule) {
  return sep_by_1(",", rule);
}

function comma_sep(rule) {
  return optional(comma_sep_1(rule));
}

function enclosed_by(l, r, rule) {
  return seq(l, rule, r);
}

function parentheses_enclosed(rule) {
  return enclosed_by("(", ")", rule);
}

function braces_enclosed(rule) {
  return enclosed_by("{", "}", rule);
}
