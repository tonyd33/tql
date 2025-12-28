CC ?= clang
# TODO: Expose the API and use the API instead of using from lib directly
CFLAGS += -std=c11 -Wall -Wpedantic -Wimplicit-fallthrough -Werror -Ilib -fPIC -g
CFLAGS += -Wno-unused-variable -Wno-unused-function -Wno-strict-prototypes
# CFLAGS += -fsanitize=address
LDFLAGS += -ltree-sitter
ARFLAGS := rcs

LIB_DIR := lib
BUILD_DIR := build
GRAMMAR_DIR := $(BUILD_DIR)/grammars
HEADERS := $(wildcard src/*.h)

SOEXT := so

TREE_SITTER_TQL := ../tree-sitter-tql

TQL_OBJS := $(patsubst $(LIB_DIR)/%.c,$(BUILD_DIR)/%.o,$(wildcard $(LIB_DIR)/*.c))
TS_TQL_OBJS := $(patsubst $(TREE_SITTER_TQL)/src/%.c,$(GRAMMAR_DIR)/tql/%.o,$(wildcard $(TREE_SITTER_TQL)/src/*.c))
TS_TYPESCRIPT_OBJS := $(patsubst $(TREE_SITTER_TYPESCRIPT)/typescript/src/%.c,$(GRAMMAR_DIR)/typescript/%.o,$(wildcard $(TREE_SITTER_TYPESCRIPT)/typescript/src/*.c))
OBJS := $(TQL_OBJS) $(TS_TQL_OBJS) $(TS_TYPESCRIPT_OBJS)

all: tql-cli libtql.a libtql.$(SOEXT)

libtql.a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

libtql.$(SOEXT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -shared $^ $(LDLIBS) -o $@

tql-cli: $(OBJS) cli/main.c
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

$(TQL_OBJS): $(HEADERS)

$(BUILD_DIR)/%.o: $(LIB_DIR)/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

$(GRAMMAR_DIR)/typescript/%.o: $(TREE_SITTER_TYPESCRIPT)/typescript/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TREE_SITTER_TYPESCRIPT)/typescript/src -c $< -o $@

$(GRAMMAR_DIR)/tql/%.o: $(TREE_SITTER_TQL)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TREE_SITTER_TQL)/src -c $< -o $@

clean:
	$(RM) -r build

.PHONY: all clean
