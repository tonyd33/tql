/**
 * @file TQL (Tree Query Language) - Option B Grammar
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  field: 20,
  child: 19,
  descendant: 18,

  not: 10,
  and: 9,
  or: 8,

  comparison: 7,
};

module.exports = grammar({
  name: "tql",

  extras: $ => [
    /\s/,
    $.comment,
  ],

  rules: {
    source_file: $ => repeat(choice(
      $.directive,
      $.query_definition,
      $.query_body,
    )),

    comment: _ => token(seq('--', /.*/)),

    // Directives
    directive: $ => seq(
      '#',
      choice(
        $.language_directive,
        $.import_directive,
      ),
    ),

    language_directive: $ => seq(
      'language',
      field('language', $.string_literal),
    ),

    import_directive: $ => seq(
      'import',
      field('path', $.string_literal),
    ),

    // Query definitions
    query_definition: $ => seq(
      'query',
      field('name', $.identifier),
      optional($.parameters),
      optional($.return_type_annotation),
      '{',
      field('body', $.query_body),
      '}',
    ),

    parameters: $ => seq(
      '(',
      optional(comma_sep1($.parameter)),
      ')',
    ),

    parameter: $ => seq(
      field('name', $.variable),
      optional(seq(':', field('type', $.type))),
    ),

    return_type_annotation: $ => seq(
      ':',
      field('type', $.type),
    ),

    query_body: $ => seq(
      optional(field('from_clause', $.from_clause)),
      optional(field('where_clause', $.where_clause)),
      field('select_clause', $.select_clause),
    ),

    from_clause: $ => seq(
      'from',
      comma_sep1($.binding),
    ),

    binding: $ => seq(
      field('expression', $.navigation_expression),
      'as',
      field('variable', $.variable),
      optional(field('optional', '?')),
    ),

    // TODO: Implement a haskell-like $ combinator
    navigation_expression: $ => choice(
      $.node_selector,
      $.variable,
      $.field_access,
      $.child_navigation,
      $.descendant_navigation,
      $.query_call,
      $.parenthesized_navigation,
    ),

    node_selector: $ => $.identifier,

    field_access: $ => prec.left(PREC.field, seq(
      field('base', $.navigation_expression),
      '.',
      field('field', $.identifier),
    )),

    child_navigation: $ => prec.left(PREC.child, seq(
      field('parent', $.navigation_expression),
      '>',
      field('child', $.navigation_expression),
    )),

    descendant_navigation: $ => prec.left(PREC.descendant, seq(
      field('parent', $.navigation_expression),
      choice('descendant::', '>>'),
      field('descendant', $.navigation_expression),
    )),

    query_call: $ => seq(
      field('name', $.identifier),
      '(',
      optional(comma_sep1(field('argument', $.expression))),
      ')',
    ),

    parenthesized_navigation: $ => seq(
      '(',
      $.navigation_expression,
      ')',
    ),

    where_clause: $ => seq(
      'where',
      field('predicate', $.predicate),
    ),

    predicate: $ => choice(
      $.comparison,
      $.logical_and,
      $.logical_or,
      $.logical_not,
      $.quantified_expression,
      $.variable,  // truthy test for optional bindings
      $.parenthesized_predicate,
    ),

    comparison: $ => prec.left(PREC.comparison, seq(
      field('left', $.expression),
      field('operator', choice('=', '!=', '~', '!~', '>', '<', '>=', '<=')),
      field('right', $.expression),
    )),

    logical_and: $ => prec.left(PREC.and, seq(
      field('left', $.predicate),
      'and',
      field('right', $.predicate),
    )),

    logical_or: $ => prec.left(PREC.or, seq(
      field('left', $.predicate),
      'or',
      field('right', $.predicate),
    )),

    logical_not: $ => prec.right(PREC.not, seq(
      'not',
      field('predicate', $.predicate),
    )),

    quantified_expression: $ => seq(
      field('quantifier', choice('forall', 'exists')),
      field('variable', $.variable),
      ':',
      field('predicate', $.predicate),
    ),

    parenthesized_predicate: $ => seq(
      '(',
      $.predicate,
      ')',
    ),

    select_clause: $ => seq(
      'select',
      field('projection', $.projection),
    ),

    projection: $ => choice(
      $.variable,
      $.string_literal,
      $.regex_literal,
      $.number_literal,
      $.function_call,
      $.field_access_expression,
      $.object_literal,
      $.array_literal,
      $.tuple_literal,
      $.subquery,
    ),

    object_literal: $ => seq(
      '{',
      optional(comma_sep1($.object_field)),
      '}',
    ),

    object_field: $ => choice(
      // Shorthand: @variable
      $.variable,
      // Full form: field: expression
      seq(
        field('key', $.identifier),
        ':',
        field('value', $.expression),
      ),
    ),

    array_literal: $ => seq(
      '[',
      optional(comma_sep1($.expression)),
      ']',
    ),

    tuple_literal: $ => seq(
      '(',
      $.expression,
      ',',
      comma_sep1($.expression),
      ')',
    ),

    subquery: $ => seq(
      '(',
      $.query_body,
      ')',
    ),

    // Expressions
    expression: $ => choice(
      $.variable,
      $.string_literal,
      $.regex_literal,
      $.number_literal,
      $.function_call,
      $.field_access_expression,
      $.object_literal,
      $.array_literal,
      $.tuple_literal,
      $.subquery,
    ),

    function_call: $ => seq(
      field('name', $.identifier),
      '(',
      optional(comma_sep1(field('argument', $.expression))),
      ')',
    ),

    field_access_expression: $ => prec.left(PREC.field, seq(
      field('base', $.expression),
      '.',
      field('field', $.identifier),
    )),

    // Types
    type: $ => choice(
      $.identifier,
      $.builtin_type,
      $.array_type,
      $.object_type,
      $.tuple_type,
      $.optional_type,
    ),

    builtin_type: _ => choice(
      'string',
      'number',
      'boolean',
      'regex',
    ),

    array_type: $ => seq(
      'Array',
      '<',
      field('element_type', $.type),
      '>',
    ),

    object_type: $ => seq(
      'Object',
      '<',
      field('value_type', $.type),
      '>',
    ),

    tuple_type: $ => seq(
      'Tuple',
      '<',
      comma_sep1(field('element_type', $.type)),
      '>',
    ),

    optional_type: $ => seq(
      field('base_type', $.type),
      '?',
    ),

    // Literals
    string_literal: $ => seq(
      "'",
      field('content', optional(repeat(choice(
        $.string_fragment,
        $.escape_sequence,
      )))),
      "'",
    ),

    string_fragment: _ => token.immediate(prec(1, /[^'\\]+/)),

    escape_sequence: _ => token.immediate(seq(
      '\\',
      choice(
        /[^xu0-7]/,
        /[0-7]{1,3}/,
        /x[0-9a-fA-F]{2}/,
        /u[0-9a-fA-F]{4}/,
        /u\{[0-9a-fA-F]+\}/,
      ),
    )),

    regex_literal: $ => seq(
      '/',
      field('pattern', optional(repeat(choice(
        $.regex_fragment,
        $.regex_escape_sequence,
      )))),
      '/',
    ),

    regex_fragment: _ => token.immediate(prec(1, /[^/\\]+/)),

    regex_escape_sequence: _ => token.immediate(seq(
      '\\',
      /./,
    )),

    number_literal: _ => /\d+(\.\d+)?/,

    // Identifiers
    variable: $ => seq('@', $.identifier),

    identifier: _ => /[a-zA-Z_][a-zA-Z0-9_]*/,
  },
});

function comma_sep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}

function comma_sep(rule) {
  return optional(comma_sep1(rule));
}
