CC := clang
CFLAGS := -Wall -Werror -Wno-unused-function -Wno-unused-variable -Wno-int-to-void-pointer-cast -Wno-void-pointer-to-int-cast -g
LDFLAGS := -ltree-sitter

TS_JSON_FLAGS := $(TREE_SITTER_JSON)/parser.c

tql: src/tql.c src/engine.c src/binding.c grammars/typescript/parser.o grammars/typescript/scanner.o
	$(CC) $(CFLAGS) $(LDFLAGS) \
		grammars/typescript/parser.o \
		grammars/typescript/scanner.o \
		src/tql.c \
		src/engine.c \
		src/binding.c \
		-o tql

grammars/typescript/parser.o:
	$(CC) $(CFLAGS) \
		$(TREE_SITTER_TYPESCRIPT)/typescript/src/parser.c \
		-I$(TREE_SITTER_TYPESCRIPT)/typescript/src \
		-c -o grammars/typescript/parser.o

grammars/typescript/scanner.o:
	$(CC) $(CFLAGS) \
		$(TREE_SITTER_TYPESCRIPT)/typescript/src/scanner.c \
		-I$(TREE_SITTER_TYPESCRIPT)/typescript/src \
		-c -o grammars/typescript/scanner.o
