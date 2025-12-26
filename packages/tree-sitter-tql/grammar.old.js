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
    global: _ => ["inheriting", "matching", "fn", "let"],
  },
  rules: {
    source_file: $ => repeat(choice($.query, $.function_declaration)),

    comment: _ => token(seq("--", /[^\r\n\u2028\u2029]*/)),

    query: $ =>
      seq(
        field("selector", $._selector),
        braces_enclosed(repeat(field("statement", $._statement))),
      ),

    _statement: $ =>
      choice(
        $.query,
        $.lexical_binding,
        $.lexical_binding_inheritance,
        $.function_match,
        $.condition,
      ),

    identifier: _ => token(seq(alpha, repeat(alphanumeric))),

    relation: _ => choice("=", "!=", "~"),

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

    lexical_binding: $ =>
      seq(
        "let",
        field("identifier", $.identifier),
        "=",
        field("value", $._expression),
      ),

    lexical_binding_inheritance: $ =>
      seq(
        "inheriting",
        $.variable_declarator,
        "matching",
        field("function", $.function_call),
      ),

    variable_declarator: $ => choice($.identifier, $.object_pattern),

    object_pattern: $ =>
      choice(braces_enclosed(comma_sep(choice($.identifier, $.pair_pattern)))),

    pair_pattern: $ =>
      seq(field("key", $.identifier), ":", field("value", $.identifier)),

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

    _expression: $ =>
      prec.left(
        choice(
          $.string_literal,
          $.attribute_identifier,
          $.function_call,
          alias($.identifier, $.variable),
        ),
      ),

    attribute_identifier: $ => seq(".", field("identifier", $.identifier)),

    // functions
    function_declaration: $ =>
      seq(
        "fn",
        field("name", $.identifier),
        parentheses_enclosed(
          comma_sep(
            field("parameter", alias($.identifier, $.function_parameter)),
          ),
        ),
        braces_enclosed(repeat(field("statement", $._statement))),
      ),

    function_call: $ =>
      seq(
        field("name", $.identifier),
        parentheses_enclosed(field("arguments", comma_sep($._expression))),
      ),

    function_match: $ => seq(optional("not"), "matching", $.function_call),

    // conditions
    condition: $ => field("condition", $._condition),
    _condition: $ =>
      choice(
        seq(parentheses_enclosed($._condition)),
        $.and_condition,
        $.or_condition,
        $.attribute_condition,
      ),

    and_condition: $ =>
      prec.left(
        seq(
          field("condition_1", $._condition),
          "&&",
          field("condition_2", $._condition),
        ),
      ),

    or_condition: $ =>
      prec.left(
        seq(
          field("condition_1", $._condition),
          "||",
          field("condition_2", $._condition),
        ),
      ),

    attribute_condition: $ =>
      seq(
        field("expression_1", $._expression),
        field("relation", $.relation),
        field("expression_2", $._expression),
      ),

    // selectors
    _selector: $ =>
      choice(
        $.universal_selector,
        alias($.identifier, $.node_type_identifier),
        $.child_selector,
        $.descendant_selector,
        $.named_field_selector,
        $.node_condition,
      ),

    universal_selector: _ => "*",

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
    named_field_selector: $ =>
      prec.left(
        seq(
          optional(field("parent", $._selector)),
          "->",
          field("field", $._selector),
        ),
      ),
    node_condition: $ =>
      seq(
        field("selector", $._selector),
        token(prec(1, "[")),
        field("condition", $._condition),
        "]",
      ),
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
