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
    source_file: $ => repeat(prec.left($.selector)),
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

    statement: $ => choice($.selector, $.assignment, $.condition),

    // selectors
    selector: $ =>
      choice(
        $._parenthesized_selector,
        $.universal_selector,
        $.node_type_selector,
        $.field_name_selector,
        $.child_selector,
        $.descendant_selector,
        $.block_selector,
        $.variable_identifier,
      ),
    _parenthesized_selector: $ => prec(100, seq("(", $.selector, ")")),
    universal_selector: _ => "*",
    node_type_selector: $ => alias($.identifier, $.node_type),
    field_name_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $.selector)),
          ".",
          field("field", alias($.identifier, $.field_name)),
        ),
      ),
    child_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $.selector)),
          ">",
          field("child", $.selector),
        ),
      ),
    descendant_selector: $ =>
      prec.left(
        seq(
          field("parent", $.selector),
          $._descendant_operator,
          field("descendant", $.selector),
        ),
      ),
    block_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $.selector)),
          braces_enclosed(field("statements", seq(sep_by(";", $.statement), optional(";")))),
        ),
      ),

    assignment: $ => seq($.variable_identifier, "<-", $._expression),

    // expressions
    _expression: $ => choice($.selector),

    // conditions
    condition: $ =>
      choice(
        $._parenthesized_condition,
        $.empty_condition,
        $.text_eq_condition,
        $.or_condition,
        $.and_condition,
      ),
    _parenthesized_condition: $ => prec(100, seq("(", $.condition, ")")),
    empty_condition: $ => seq("!", $._expression),
    text_eq_condition: $ => seq($._expression, "=", $.string_literal),
    or_condition: $ => prec.left(seq($.condition, "||", $.condition)),
    and_condition: $ => prec.left(seq($.condition, "&&", $.condition)),
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
