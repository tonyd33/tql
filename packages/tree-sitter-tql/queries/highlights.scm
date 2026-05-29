[ "with"
  "where"
  "select"
  "any"
  "all"
  "in"
  "as"
  "and"
  "or"
] @keyword

(comment) @comment

(variable) @variable

(field_access field: (_) @attribute)
(descendant_navigation descendant: (_) @property)
(child_navigation child: (_) @property)

(regex_literal) @string.regex
