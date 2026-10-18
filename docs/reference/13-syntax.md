# Syntax reference

This chapter gives the whole grammar. Each other chapter gives the
fragment it defines, and the two agree. The notation is in
[Notation](README.md#notation).

Every comma-separated sequence `x ("," x)*` also accepts a trailing `,`;
the productions leave it out.

## Lexical syntax

```
lower      ::= [a-z] [a-zA-Z0-9_']*   |   _ [a-zA-Z0-9_']+
upper      ::= [A-Z] [a-zA-Z0-9_']*
qualified  ::= (upper ".")+ (lower | upper)
primitive  ::= "%" (lower | upper)

varsym     ::= an operator symbol
integer    ::= "-"? [0-9]+
string     ::= '"' (char | escape)* '"'
escape     ::= \"  |  \\  |  \n  |  \t  |  \r
regex      ::= 'r"' raw* '"'
kindlit    ::= ":" [a-zA-Z_] [a-zA-Z0-9_]*
```

Comments, keywords, operator symbols and the whitespace rules for `.`,
`#`, `@`, `:` and `-` are in [Lexical structure](01-lexical.md).

## Names

```
var      ::= lower | "(" varsym ")"
qvar     ::= var | qualified
con      ::= upper
qcon     ::= con | qualified
tycon    ::= upper
qtycon   ::= tycon | qualified
cls      ::= upper
qcls     ::= cls | qualified
tyvar    ::= lower
label    ::= lower
field    ::= lower
modid    ::= upper ("." upper)*

op       ::= varsym | "`" var "`"
varop    ::= op
qop      ::= varsym | ":" | "`" (qvar | qcon) "`"

literal  ::= integer | string | regex | kindlit
```

`qvar` takes a `qualified` that ends in a lower name, and `qcon`,
`qtycon` and `qcls` one that ends in an upper name.

## Modules

```
module   ::= header? import* topdecl*
header   ::= "module" modid exports? grammars? ";"
exports  ::= "(" (export ("," export)*)? ")"
export   ::= qvar | qtycon ("(" ".." ")")? | qcls ("(" ".." ")")? | "module" modid
grammars ::= "for" lower ("," lower)*

import   ::= "import" modid items? ("as" modid)? ";"
items    ::= "(" (item ("," item)*)? ")" | "hiding" "(" (item ("," item)*)? ")"
item     ::= var | tycon ("(" ".." ")")? | cls ("(" ".." ")")?
```

## Declarations

```
topdecl  ::= "data" simpletype ("=" constrs)? deriving* ";"
           | "newtype" simpletype "=" con atype deriving* ";"
           | "type" simpletype "=" type ";"
           | "class" (context "=>")? cls tyvar "where" "{" (cdecl ";")* "}" ";"
           | "instance" (context "=>")? qcls inst "where" "{" (idecl ";")* "}" ";"
           | "pattern" con var* "<-" pat ";"
           | "pattern" con "::" sigtype ";"
           | fixity ";"
           | rule ";"
           | decl ";"

decl     ::= vars "::" sigtype
           | funlhs "=" exp
           | pat "=" exp

cdecl    ::= vars "::" sigtype | funlhs "=" exp | "minimal" formula | "deriving" primitive
idecl    ::= funlhs "=" exp
formula  ::= formula "|" formula | formula "," formula | "(" formula ")" | var

inst     ::= qtycon tyvar*
           | "(" qtycon tyvar* ")"
           | "(" tyvar ("," tyvar)+ ")"   |   "(" ")"
           | "[" tyvar "]"
           | "(" "->" ")" tyvar*

fixity   ::= ("infixl" | "infixr" | "infix") integer op ("," op)*
rule     ::= "rule" string ("forall" var+ ".")? exp "=" exp

simpletype ::= tycon tvbind*
tvbind     ::= tyvar | "(" tyvar "::" kind ")"
constrs    ::= con atype* ("|" con atype*)*
deriving   ::= "deriving" "newtype"? "(" (qcls ("," qcls)*)? ")"
funlhs     ::= var apat* | apat varop apat
vars       ::= var ("," var)*
```

In a `minimal` formula, `,` binds tighter than `|`. Only library modules
declare a `rule` ([The optimiser](12-core.md#the-optimiser)).

## Types

```
sigtype    ::= (context "=>")? type
context    ::= constraint | "(" (constraint ("," constraint)*)? ")"
constraint ::= qcls atype | "All" qcls atype

type     ::= btype ("->" type)?
btype    ::= btype atype | atype
atype    ::= tyvar | qtycon
           | "(" type ")"
           | "(" type ("," type)+ ")"   |   "(" ")"
           | "[" type "]"
           | "(" "->" ")"   |   "(" ","+ ")"
           | "{" (label ":" type ("," label ":" type)*)? ("|" tyvar)? "}"

kind     ::= "Type" | "Row" | kind "->" kind | "(" kind ")"
```

## Expressions

```
exp      ::= lexp (qop lexp)*

lexp     ::= blockexp | fexp
blockexp ::= "\" apat+ "->" exp
           | "let" binds "in" exp
           | "if" exp "then" exp "else" exp
           | "case" exp "of" "{" (alt ";")* "}"
           | "do" "{" (stmt ";")* exp ";" "}"

fexp     ::= fexp arg | aexp
arg      ::= aexp | blockexp

aexp     ::= qvar | qcon | primitive | literal
           | "(" exp ")"
           | "(" exp ("," exp)+ ")"   |   "(" ")"
           | "[" (exp ("," exp)*)? "]"
           | "{" (label "=" exp ("," label "=" exp)*)? "}"
           | "(" exp "::" sigtype ")"
           | "(" qop ")"   |   "(" lexp qop ")"   |   "(" qop lexp ")"
           | "(" ("." label)+ ")"
           | aexp "." label
           | aexp "#" field
           | "#" field

alt      ::= pat ("if" exp)? "->" exp
stmt     ::= exp | pat "<-" exp | "let" "{" (decl ";")* "}" | "let" decl (";" decl)*
binds    ::= "{" (decl ";")* "}" | (decl ";")+
```

A chain `lexp qop lexp ...` is grouped by the operators' fixities
([Operator application](02-expressions.md#operator-application)).

## Patterns

```
pat      ::= apat
           | qcon apat+
           | pat ":" pat
           | pat "&" pat
           | var "@" apat
           | "!" apat

apat     ::= var | "_" | literal
           | qcon
           | "(" pat ")"
           | "(" pat ("," pat)+ ")"   |   "(" ")"
           | "[" (pat ("," pat)*)? "]"
           | "(" exp "->" pat ")"
           | kindlit "{" (fpat ("," fpat)*)? "}"
           | "{" fpat ("," fpat)* "}"

fpat     ::= "#" field "=" pat
```
