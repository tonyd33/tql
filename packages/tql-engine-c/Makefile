CC ?= clang
# TODO: Expose the API and use the API instead of using from lib directly
CFLAGS += -std=c11 -Wall -Wpedantic -Wimplicit-fallthrough -Werror -fPIC -g
CFLAGS += -Wno-unused-variable -Wno-unused-function -Wno-strict-prototypes
CFLAGS += -fsanitize=address
LDFLAGS += -ltree-sitter
ARFLAGS := rcs

LIB_DIR := lib
BUILD_DIR := build
GRAMMAR_DIR := $(BUILD_DIR)/grammars
HEADERS := $(wildcard src/*.h)

SOEXT := so

TS_TQL := ../tree-sitter-tql
TS_TQL_OBJS := $(patsubst $(TS_TQL)/src/%.c,$(GRAMMAR_DIR)/tql/%.o,$(wildcard $(TS_TQL)/src/*.c))

TS_BASH_OBJS := $(patsubst $(TS_BASH)/src/%.c,$(GRAMMAR_DIR)/bash/%.o,$(wildcard $(TS_BASH)/src/*.c))
TS_C_OBJS := $(patsubst $(TS_C)/src/%.c,$(GRAMMAR_DIR)/c/%.o,$(wildcard $(TS_C)/src/*.c))
TS_CPP_OBJS := $(patsubst $(TS_CPP)/src/%.c,$(GRAMMAR_DIR)/cpp/%.o,$(wildcard $(TS_CPP)/src/*.c))
TS_CSS_OBJS := $(patsubst $(TS_CSS)/src/%.c,$(GRAMMAR_DIR)/css/%.o,$(wildcard $(TS_CSS)/src/*.c))
TS_GO_OBJS := $(patsubst $(TS_GO)/src/%.c,$(GRAMMAR_DIR)/go/%.o,$(wildcard $(TS_GO)/src/*.c))
TS_HASKELL_OBJS := $(patsubst $(TS_HASKELL)/src/%.c,$(GRAMMAR_DIR)/haskell/%.o,$(wildcard $(TS_HASKELL)/src/*.c))
TS_JAVA_OBJS := $(patsubst $(TS_JAVA)/src/%.c,$(GRAMMAR_DIR)/java/%.o,$(wildcard $(TS_JAVA)/src/*.c))
TS_JAVASCRIPT_OBJS := $(patsubst $(TS_JAVASCRIPT)/src/%.c,$(GRAMMAR_DIR)/javascript/%.o,$(wildcard $(TS_JAVASCRIPT)/src/*.c))
TS_JSON_OBJS := $(patsubst $(TS_JSON)/src/%.c,$(GRAMMAR_DIR)/json/%.o,$(wildcard $(TS_JSON)/src/*.c))
TS_PYTHON_OBJS := $(patsubst $(TS_PYTHON)/src/%.c,$(GRAMMAR_DIR)/python/%.o,$(wildcard $(TS_PYTHON)/src/*.c))
TS_RUST_OBJS := $(patsubst $(TS_RUST)/src/%.c,$(GRAMMAR_DIR)/rust/%.o,$(wildcard $(TS_RUST)/src/*.c))
TS_TYPESCRIPT_OBJS := $(patsubst $(TS_TYPESCRIPT)/typescript/src/%.c,$(GRAMMAR_DIR)/typescript/%.o,$(wildcard $(TS_TYPESCRIPT)/typescript/src/*.c))

TQL_OBJS := $(patsubst $(LIB_DIR)/%.c,$(BUILD_DIR)/%.o,$(wildcard $(LIB_DIR)/*.c))
TS_OBJS := $(TS_BASH_OBJS)\
	   $(TS_C_OBJS)\
	   $(TS_CPP_OBJS)\
	   $(TS_CSS_OBJS)\
	   $(TS_GO_OBJS)\
	   $(TS_HASKELL_OBJS)\
	   $(TS_JAVA_OBJS)\
	   $(TS_JAVASCRIPT_OBJS)\
	   $(TS_JSON_OBJS)\
	   $(TS_PYTHON_OBJS)\
	   $(TS_RUST_OBJS)\
	   $(TS_TYPESCRIPT_OBJS)
OBJS := $(TQL_OBJS) $(TS_TQL_OBJS) $(TS_OBJS)

all: tql-cli libtql.a libtql.$(SOEXT)

libtql.a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

libtql.$(SOEXT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -shared $^ $(LDLIBS) -o $@

tql-cli: $(OBJS) cli/main.c
	$(CC) $(CFLAGS) -Ilib $(LDFLAGS) $^ -o $@

$(TQL_OBJS): $(HEADERS)

$(BUILD_DIR)/%.o: $(LIB_DIR)/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

$(GRAMMAR_DIR)/bash/%.o: $(TS_BASH)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_BASH)/src -c $< -o $@

$(GRAMMAR_DIR)/typescript/%.o: $(TS_TYPESCRIPT)/typescript/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_TYPESCRIPT)/typescript/src -c $< -o $@

$(GRAMMAR_DIR)/c/%.o: $(TS_C)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_C)/src -c $< -o $@

$(GRAMMAR_DIR)/cpp/%.o: $(TS_CPP)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_CPP)/src -c $< -o $@

$(GRAMMAR_DIR)/css/%.o: $(TS_CSS)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_CSS)/src -c $< -o $@

$(GRAMMAR_DIR)/go/%.o: $(TS_GO)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_GO)/src -c $< -o $@

$(GRAMMAR_DIR)/haskell/%.o: $(TS_HASKELL)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -Wno-implicit-fallthrough -I$(TS_HASKELL)/src -c $< -o $@

$(GRAMMAR_DIR)/java/%.o: $(TS_JAVA)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_JAVA)/src -c $< -o $@

$(GRAMMAR_DIR)/javascript/%.o: $(TS_JAVASCRIPT)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_JAVASCRIPT)/src -c $< -o $@

$(GRAMMAR_DIR)/json/%.o: $(TS_JSON)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_JSON)/src -c $< -o $@

$(GRAMMAR_DIR)/python/%.o: $(TS_PYTHON)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_PYTHON)/src -c $< -o $@

$(GRAMMAR_DIR)/rust/%.o: $(TS_RUST)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -Wno-extra-semi -I$(TS_RUST)/src -c $< -o $@

$(GRAMMAR_DIR)/tql/%.o: $(TS_TQL)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) -I$(TS_TQL)/src -c $< -o $@

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all clean
