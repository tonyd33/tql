/**
 * @file TQL (Tree Query Language)
 * @author Tony Du
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const UPPER_NAME = /[A-Z][a-zA-Z0-9_]*/;
const LOWER_NAME = /[a-z_][a-zA-Z0-9_]*/;

const PREC = {
  dollar: 1,
  // biome-ignore lint/suspicious/noThenProperty: false positive
  then: 2,
  pipe: 3,
  union: 4,
  or: 5,
  and: 6,
  cmp: 7,
  cons: 8,
  add: 9,
  mul: 10,
  compose: 11,
  infix: 12,
  app: 13,
  field: 14,
};

module.exports = grammar({
  name: "tql",

  extras: $ => [/\s/, $.comment],

  word: $ => $.identifier,

  inline: $ => [$._constructor],

  // A `do` statement is a pattern or an expression until `<-`, and a pattern's
  // `(` opens a view or a parenthesized pattern until `->` or `)`. `:k {` is a
  // node pattern or `:k` applied to a record until `#` or `<-`.
  conflicts: $ => [
    [$.list_pattern, $.list],
    [$._simple_pattern, $._primary],
    [$.constructor_pattern, $._primary],
    [$.node_pattern, $._primary],
  ],

  rules: {
    source_file: $ =>
      seq(
        optional(field("header", $.module_header)),
        repeat(field("import", $.import_declaration)),
        repeat($._declaration),
      ),

    module_header: $ =>
      seq(
        "module",
        field("name", $.module_name),
        optional(field("exports", $.item_list)),
        optional(seq("for", sep1(field("grammar", $.identifier), ","))),
        ";",
      ),

    import_declaration: $ =>
      seq(
        "import",
        field("module", $.module_name),
        optional(
          choice(
            field("items", $.item_list),
            seq("hiding", field("hiding", $.item_list)),
          ),
        ),
        optional(seq("as", field("qualifier", $.module_name))),
        ";",
      ),

    item_list: $ => seq("(", optional(sep_trailing($.item, ",")), ")"),

    item: $ =>
      choice(
        field("name", value_name($)),
        seq(
          field("name", $.type_identifier),
          optional(field("constructors", $.all_constructors)),
        ),
        seq("pattern", field("synonym", $.type_identifier)),
      ),

    all_constructors: _ => seq("(", "..", ")"),

    module_name: _ => token(seq(UPPER_NAME, repeat(seq(".", UPPER_NAME)))),

    qualified_identifier: _ =>
      token(seq(UPPER_NAME, repeat(seq(".", UPPER_NAME)), ".", LOWER_NAME)),

    qualified_type_identifier: _ =>
      token(seq(UPPER_NAME, repeat1(seq(".", UPPER_NAME)))),

    comment: _ => token(seq("--", /.*/)),

    _declaration: $ =>
      choice(
        $.signature,
        $.definition,
        $.data_declaration,
        $.type_alias,
        $.pattern_synonym,
        $.pattern_signature,
        $.class_declaration,
        $.instance_declaration,
      ),

    class_declaration: $ =>
      seq(
        "class",
        optional(seq(field("context", $.context), "=>")),
        field("name", $.type_identifier),
        field("parameter", $._type_variable),
        "where",
        "{",
        repeat(field("method", $.signature)),
        "}",
        ";",
      ),

    instance_declaration: $ =>
      seq(
        "instance",
        optional(seq(field("context", $.context), "=>")),
        field("class", $.type_identifier),
        field("type", $._type_operand),
        "where",
        "{",
        repeat(field("method", $.definition)),
        "}",
        ";",
      ),

    pattern_synonym: $ =>
      seq(
        "pattern",
        field("name", $.type_identifier),
        repeat(field("parameter", $.identifier)),
        "<-",
        field("pattern", $._pattern),
        ";",
      ),

    pattern_signature: $ =>
      seq(
        "pattern",
        field("name", $.type_identifier),
        "::",
        field("type", $._type),
        ";",
      ),

    data_declaration: $ =>
      seq(
        "data",
        field("name", $.type_identifier),
        repeat(field("parameter", $._type_variable)),
        "=",
        sep1(field("constructor", $.constructor_declaration), "|"),
        optional(field("deriving", $.deriving)),
        ";",
      ),

    deriving: $ =>
      seq("deriving", "(", sep1(field("class", $.type_identifier), ","), ")"),

    type_alias: $ =>
      seq(
        "type",
        field("name", $.type_identifier),
        repeat(field("parameter", $._type_variable)),
        "=",
        field("type", $._type),
        ";",
      ),

    constructor_declaration: $ =>
      seq(
        field("name", $.type_identifier),
        repeat(field("field", $._type_operand)),
      ),

    signature: $ =>
      seq(
        field("name", value_name($)),
        "::",
        optional(seq(field("context", $.context), "=>")),
        field("type", $._type),
        ";",
      ),

    context: $ =>
      choice(
        $.class_constraint,
        seq(
          "(",
          $.class_constraint,
          repeat1(seq(",", $.class_constraint)),
          ")",
        ),
      ),

    class_constraint: $ =>
      seq(
        field("class", $.type_identifier),
        field("variable", $._type_variable),
      ),

    definition: $ =>
      seq(
        field("name", value_name($)),
        repeat(field("parameter", $.identifier)),
        "=",
        field("body", $._expression),
        ";",
      ),

    _expression: $ =>
      choice(
        $.dollar_application,
        $.then,
        $.union,
        $.pipe,
        $.logical_or,
        $.logical_and,
        $.comparison,
        $.cons,
        $.additive,
        $.multiplicative,
        $.composition,
        $.infix_application,
        $.application,
        $.field_access,
        $.navigation,
        $._primary,
      ),

    // Ideally, this would be regular token to TQL but the precedence
    // is what keeps it hardcoded into the grammar.
    dollar_application: $ =>
      prec.right(
        PREC.dollar,
        seq(
          field("function", $._expression),
          "$",
          field("argument", $._expression),
        ),
      ),

    // biome-ignore lint/suspicious/noThenProperty: false positive
    then: $ =>
      prec.left(
        PREC.then,
        seq(field("left", $._expression), ">>", field("right", $._expression)),
      ),

    union: $ =>
      prec.left(
        PREC.union,
        seq(field("left", $._expression), "<|>", field("right", $._expression)),
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

    comparison: $ =>
      prec.left(
        PREC.cmp,
        seq(
          field("left", $._expression),
          field("operator", choice("=", "!=", "<", "<=", ">", ">=", "~", "!~")),
          field("right", $._expression),
        ),
      ),

    cons: $ =>
      prec.right(
        PREC.cons,
        seq(
          field("left", $._expression),
          $._cons_operator,
          field("right", $._expression),
        ),
      ),

    // An attached `:` outranks the kind token, so `x:xs` is cons and `x :xs`
    // applies `x` to a kind.
    _cons_operator: _ => choice(token.immediate(prec(1, ":")), ":"),

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

    infix_application: $ =>
      prec.left(
        PREC.infix,
        seq(
          field("left", $._expression),
          "`",
          field(
            "function",
            choice($.identifier, $.qualified_identifier, $._constructor),
          ),
          "`",
          field("right", $._expression),
        ),
      ),

    application: $ =>
      prec.left(
        PREC.app,
        seq(field("function", $._expression), field("argument", $._expression)),
      ),

    composition: $ =>
      prec.right(
        PREC.compose,
        seq(field("left", $._expression), ".", field("right", $._expression)),
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

    navigation: $ =>
      prec.left(
        PREC.field,
        seq(
          field("node", $._expression),
          token.immediate("#"),
          field("field", $.field_name),
        ),
      ),

    leading_navigation: $ => seq("#", field("field", $.field_name)),

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

    _do_items: $ => sep_trailing($._do_statement, ";"),

    _do_statement: $ =>
      choice($.bind_statement, $.let_statement, $._expression),

    bind_statement: $ =>
      seq(field("pattern", $._pattern), "<-", field("value", $._expression)),

    let_statement: $ =>
      seq("let", field("bindings", choice($.binding, $.binding_group))),

    case_expression: $ =>
      seq(
        "case",
        field("scrutinee", $._expression),
        "of",
        "{",
        sep_trailing($.case_alternative, ";"),
        "}",
      ),

    case_alternative: $ =>
      seq(
        field("pattern", $._pattern),
        optional(seq("if", field("guard", $._expression))),
        "->",
        field("body", $._expression),
      ),

    _pattern: $ => choice($.conjunction_pattern, $._conjunct),

    _conjunct: $ =>
      choice($.cons_pattern, $.constructor_pattern, $._simple_pattern),

    conjunction_pattern: $ =>
      prec.left(
        seq(field("left", $._pattern), "&", field("right", $._conjunct)),
      ),

    cons_pattern: $ =>
      prec.right(
        seq(
          field("head", choice($.constructor_pattern, $._simple_pattern)),
          $._cons_operator,
          field("tail", $._conjunct),
        ),
      ),

    list_pattern: $ => seq("[", optional(sep_trailing($._pattern, ",")), "]"),

    constructor_pattern: $ =>
      seq(
        field("constructor", $._constructor),
        repeat(field("argument", $._atomic_pattern)),
      ),

    _atomic_pattern: $ => choice($._constructor, $._simple_pattern),

    _simple_pattern: $ =>
      choice(
        $.identifier,
        $.list_pattern,
        $.parenthesized_pattern,
        $.view_pattern,
        $.as_pattern,
        $.number,
        $.string,
        $.regex,
        $.boolean,
        // `C :k { .. }` applies `C` to one node pattern.
        prec(-1, $.kind),
        $.node_pattern,
      ),

    // `{}` is not a pattern.
    node_pattern: $ =>
      choice(
        seq(
          field("kind", $.kind),
          "{",
          optional(sep_trailing(field("field", $.field_pattern), ",")),
          "}",
        ),
        seq("{", sep_trailing(field("field", $.field_pattern), ","), "}"),
      ),

    field_pattern: $ =>
      seq("#", field("name", $.field_name), "=", field("pattern", $._pattern)),

    as_pattern: $ =>
      seq(
        field("name", $.identifier),
        token.immediate("@"),
        field("pattern", $._atomic_pattern),
      ),

    view_pattern: $ =>
      seq(
        "(",
        field("view", $._expression),
        "->",
        field("pattern", $._pattern),
        ")",
      ),

    parenthesized_pattern: $ => seq("(", $._pattern, ")"),

    of_shape: $ => seq("of_shape", field("pattern", $._atomic_pattern)),

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
        $.leading_navigation,
        $.kind,
        $.identifier,
        $.number,
        $.string,
        $.boolean,
        $.regex,
        $.list,
        $.record,
        $.parenthesized,
        $.operator_name,
        $.left_section,
        $.right_section,
        $.lambda,
        $.let_expression,
        $.do_expression,
        $.if_expression,
        $.case_expression,
        $.of_shape,
        $.qualified_identifier,
        $._constructor,
      ),

    kind: _ => token(seq(":", /[a-zA-Z_][a-zA-Z0-9_]*/)),

    operator_name: $ =>
      seq("(", field("operator", $._bare_section_operator), ")"),

    left_section: $ =>
      seq(
        "(",
        field("left", $._expression),
        field("operator", $._left_section_operator),
        ")",
      ),

    right_section: $ =>
      seq(
        "(",
        field("operator", $._right_section_operator),
        field("right", $._expression),
        ")",
      ),

    // An attached `:` valid after `(` outranks the kind token in `(:xs)`.
    _bare_section_operator: $ => choice($._section_operator, ":", "-"),

    _left_section_operator: $ =>
      choice($._section_operator, $._cons_operator, "-"),

    // `(- 1)` must not be a function beside the number `(-1)`. An attached
    // `:` valid after `(` outranks the kind token in `(:xs)`.
    _right_section_operator: $ => choice($._section_operator, ":"),

    _section_operator: $ =>
      choice(
        "$",
        ">>",
        "|",
        "<|>",
        "or",
        "and",
        "=",
        "!=",
        "<",
        "<=",
        ">",
        ">=",
        "~",
        "!~",
        "+",
        "*",
        "/",
        "%",
        ".",
        $.backtick_operator,
      ),

    backtick_operator: $ =>
      seq(
        "`",
        field(
          "function",
          choice($.identifier, $.qualified_identifier, $._constructor),
        ),
        "`",
      ),

    parenthesized: $ => seq("(", $._expression, ")"),

    list: $ => seq("[", optional(sep_trailing($._expression, ",")), "]"),

    record: $ => seq("{", optional(sep_trailing($.record_field, ",")), "}"),

    record_field: $ =>
      seq(field("name", $.identifier), "=", field("value", $._expression)),

    _type: $ => choice($.function_type, $._type_atom),

    function_type: $ =>
      prec.right(seq(field("from", $._type_atom), "->", field("to", $._type))),

    _type_atom: $ =>
      choice(
        $.filter_type,
        $.type_application,
        $.list_type,
        $.record_type,
        $._constructor,
        $._type_variable,
        $.parenthesized_type,
      ),

    type_application: $ =>
      seq(
        field("constructor", $._constructor),
        repeat1(field("argument", $._type_operand)),
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
        $._constructor,
        $._type_variable,
        $.parenthesized_type,
      ),

    list_type: $ => seq("[", $._type, "]"),

    record_type: $ =>
      choice(
        seq("{", optional(sep_trailing($.record_type_field, ",")), "}"),
        seq(
          "{",
          optional(sep1($.record_type_field, ",")),
          "|",
          field("row", $._type_variable),
          "}",
        ),
      ),

    record_type_field: $ =>
      seq(field("name", $.identifier), ":", field("type", $._type)),

    parenthesized_type: $ => seq("(", $._type, ")"),

    // A constructor or type name as a use site may write it, qualified or not.
    _constructor: $ => choice($.type_identifier, $.qualified_type_identifier),

    type_identifier: _ => UPPER_NAME,

    // Must be the word token, so keywords are not type variables.
    _type_variable: $ => alias($.identifier, $.type_variable),

    identifier: _ => LOWER_NAME,

    number: _ => token(seq(optional("-"), /[0-9]+/)),

    string: _ => token(seq('"', repeat(choice(/[^"\\]/, seq("\\", /./))), '"')),

    boolean: _ => choice("true", "false"),

    regex: _ => token(seq('r"', repeat(choice(/[^"\\]/, seq("\\", /./))), '"')),
  },
});

/**
 * A value's name where a declaration or item may start, which may be spelled
 * `pattern`.
 * @param {GrammarSymbols<string>} $
 */
function value_name($) {
  return choice($.identifier, alias("pattern", $.identifier));
}

function sep1(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)));
}

/**
 * One or more `rule`, separated by `sep`, with an optional trailing `sep`.
 * @param {RuleOrLiteral} rule
 * @param {RuleOrLiteral} sep
 */
function sep_trailing(rule, sep) {
  return seq(rule, repeat(seq(sep, rule)), optional(sep));
}
