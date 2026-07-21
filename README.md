# TQL

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
tql query --grammar=c ". > function_definition.declarator.declarator | text" main.c
```

Output:

```
main.c: add
main.c: strlen
main.c: main
```

Find all function argument names

```sh
tql query --grammar=c ". > function_definition.declarator > parameter_list >> identifier | text" main.c
```

Output:

```
main.c: a
main.c: b
main.c: s
main.c: argc
main.c: argv
```

Find all function argument names with type int

```sh
tql query --grammar=c "
. > function_definition.declarator
| .parameters > parameter_declaration
| select(.type | text = 'int')
| .declarator
| text
" main.c

```

Output:

```
main.c: a
main.c: b
main.c: argc
```

Find all function names with an argument with type int

```sh
tql query --grammar=c "
. > function_definition.declarator as @func_decl
| select(any(@func_decl.parameters > parameter_declaration; .type | text = 'int'))
| @func_decl.declarator
| text
" main.c
```

Output:

```
main.c: add
main.c: main
```

Find all function names with an argument with type int, along with that function's parameters

```sh
tql query --grammar=c "
. > function_definition.declarator as @func_decl
| select(any(@func_decl.parameters > parameter_declaration; .type | text = 'int'))
| {
    name: @func_decl.declarator | text,
    params: [@func_decl.parameters > parameter_declaration | text]
  }
" main.c
```

Output:

```
main.c: {"name": "add", "params": ["int a", "int b"]}
main.c: {"name": "main", "params": ["int argc", "char **argv"]}
```

### Grammars

List available grammars

```sh
tql grammar list
```

Example output:

```
Built-in grammars:
  c

Dynamic grammars:
  javascript  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  zig  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  rust  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  tsx  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  python  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  typescript  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  go  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  cpp  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
  c  /home/tony/code/tql/packages/tql-engine-zig/zig-out/lib/tql/grammars
```

## Installation

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
