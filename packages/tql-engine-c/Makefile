CC := clang
CFLAGS := -Wall -Werror -Wno-unused-function -Wno-unused-variable -Wno-int-to-void-pointer-cast -Wno-void-pointer-to-int-cast -g
LDFLAGS := -ltree-sitter

TS_JSON_FLAGS := $(TREE_SITTER_JSON)/parser.c

tql: src/main.c src/dyn_array.h build/engine.o build/binding.o grammars/typescript/parser.o grammars/typescript/scanner.o
	$(CC) $(CFLAGS) $(LDFLAGS) \
		grammars/typescript/parser.o \
		grammars/typescript/scanner.o \
		build/engine.o \
		build/binding.o \
		src/main.c \
		-o tql

build/engine.o: src/engine.c src/engine.h src/dyn_array.h
	$(CC) $(CFLAGS) \
		-c src/engine.c \
		-o build/engine.o

build/binding.o: src/binding.c src/binding.h src/dyn_array.h
	$(CC) $(CFLAGS) \
		-c src/binding.c \
		-o build/binding.o

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
