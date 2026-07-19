[ "def"
  "as"
  "is"
  "and"
  "or"
  "not"
] @keyword

(null_literal) @constant.builtin

(comment) @comment

(variable) @variable
(dot_field_access field: (_) @attribute)
(field_access field: (_) @attribute)
(descendant_navigation descendant: (_) @property)
(child_navigation child: (_) @property)

(function_definition name: (_) @function)
(function_call name: (_) @function)

(string_literal) @string
(regex_literal) @string.regex
(number_literal) @number
