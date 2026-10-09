[ "let"
  "in"
  "do"
  "if"
  "then"
  "else"
  "and"
  "or"
  "case"
  "of"
  "type"
  "data"
  "module"
  "import"
  "hiding"
  "for"
  "as"
  "pattern"
  "of_shape"
  "class"
  "instance"
  "where"
  "deriving"
] @keyword

(module_name) @module
(qualified_identifier) @variable
(qualified_type_identifier) @type

(comment) @comment

(boolean) @constant.builtin

(kind) @type

(navigation field: (_) @attribute)
(leading_navigation field: (_) @attribute)
(field_pattern name: (_) @attribute)
(field_access field: (_) @property)
(record_field name: (_) @property)
(record_type_field name: (_) @property)

(definition name: (_) @function)
(definition parameter: (_) @variable.parameter)
(signature name: (_) @function)
(binding name: (_) @function)
(binding parameter: (_) @variable.parameter)
(lambda parameter: (_) @variable.parameter)
(pattern_synonym parameter: (_) @variable.parameter)
(bind_statement pattern: (identifier) @variable)
(as_pattern name: (_) @variable)
(infix_application function: (identifier) @function)
(backtick_operator function: (identifier) @function)

"Filter" @type.builtin
(type_identifier) @type
(type_variable) @type

[ "&" "@" ] @operator

(string) @string
(regex) @string.regex
(number) @number
