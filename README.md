# TQL

## Documentation

* Coming soon
* Try TQL online: https://tonyd33.github.io/tql/

## Usage

```sh
tql --help
tql version
```

### Queries

Example C source file:

```c
#include <stddef.h>
#include <stdio.h>

int add(int a, int b) {
  return a + b;
}

size_t strlen(const char *s) {
  const char *p = s;
  while (*p++) {}
  return p - s;
}

int main(int argc, char **argv) {
  printf("Hello world\n");
  printf("strlen(\"Hello world\") = %lu\n", strlen("Hello world"));
  printf("add(1, 2) = %d\n", add(1, 2));
  return 0;
}
```

Find all function names

```sh
tql query --grammar=c '
main = descendants_of_kind :function_definition | #declarator | #declarator | arr text;
' main.c
```

Output:

```
main.c: ["add","strlen","main"]
```

Find all function argument names

```sh
tql query --grammar=c '
main =
  descendants_of_kind :function_definition
  | #declarator
  | #parameters
  | descendants_of_kind :identifier
  | arr text;
' main.c
```

Output:

```
main.c: ["a","b","s","argc","argv"]
```

Find all function argument names with type int

```sh
tql query --grammar=c '
int_type = #type | arr text | keep (\t -> t = "int");

main =
  descendants_of_kind :function_definition
  | #declarator
  | #parameters
  | children_of_kind :parameter_declaration
  | keep (has int_type)
  | #declarator
  | arr text;
' main.c
```

Output:

```
main.c: ["a","b","argc"]
```

Find all function names with an argument with type int

```sh
tql query --grammar=c '
int_type = #type | arr text | keep (\t -> t = "int");
int_params = #declarator | #parameters | children_of_kind :parameter_declaration | keep (has int_type);

main =
  descendants_of_kind :function_definition
  | keep (has int_params)
  | #declarator
  | #declarator
  | arr text;
' main.c
```

Output:

```
main.c: ["add","main"]
```

Find all function names with an argument with type int, along with that function's parameters

```sh
tql query --grammar=c '
params = #declarator | #parameters | children_of_kind :parameter_declaration;
int_type = #type | arr text | keep (\t -> t = "int");

main root = do {
  f <- descendants_of_kind :function_definition root;
  guard $ has (params | keep (has int_type)) f;
  name <- (#declarator | #declarator) f;
  return { name = text name, params = (params | arr text) f };
};
' main.c
```

Output:

```
main.c: [{"name":"add","params":["int a","int b"]},{"name":"main","params":["int argc","char **argv"]}]
```

### Grammars

List available grammars

```sh
tql grammar list
```

Example output:

```
Built-in grammars:
  (none)

Dynamic grammars:
  c  /home/user/.local/share/tql/grammars
  python  /home/user/.local/share/tql/grammars
  rust  /home/user/.local/share/tql/grammars
  typescript  /home/user/.local/share/tql/grammars
```

## Installation


### Prebuilt binaries

Download from [releases](https://github.com/tonyd33/tql/releases)

### Build from source

Requirements:

* Zig 0.16.0

```sh
cd packages/tql-engine-zig

# build with available grammars
zig build -Dgrammars=available

# build with only c grammar
zig build -Dgrammars=c
```
