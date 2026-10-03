[ "let"
  "in"
  "do"
  "if"
  "then"
  "else"
  "and"
  "or"
] @keyword

(comment) @comment

(boolean) @constant.builtin

(kind) @type

(navigation field: (_) @attribute)
(leading_navigation field: (_) @attribute)
(field_access field: (_) @property)
(record_field name: (_) @property)
(record_type_field name: (_) @property)

(definition name: (_) @function)
(definition parameter: (_) @variable.parameter)
(signature name: (_) @function)
(binding name: (_) @function)
(binding parameter: (_) @variable.parameter)
(lambda parameter: (_) @variable.parameter)
(bind_statement name: (_) @variable)
(infix_application function: (identifier) @function)
(backtick_operator function: (identifier) @function)

"Filter" @type.builtin
(type_identifier) @type
(type_variable) @type

(string) @string
(regex) @string.regex
(number) @number
