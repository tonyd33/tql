CC := cc
BUILD ?= release

CFLAGS_ALL += -std=c11 -Wall -Wextra -Wpedantic -Wno-unused-parameter -fPIC
CFLAGS_DEBUG += -Wshadow \
		-Wno-sign-compare \
		-Wswitch \
		-Wimplicit-fallthrough \
		-Wno-unused-variable \
		-Wno-unused-function \
		-Wno-strict-prototypes \
		-Werror \
		-DDEBUG \
		-g \
		-fsanitize=address
CFLAGS_RELEASE += -O3

TS_LANGS ?= bash \
	   c \
	   cpp \
	   css \
	   go \
	   haskell \
	   java \
	   javascript \
	   json \
	   python \
	   rust \
	   tsx \
	   typescript

CFLAGS += $(CFLAGS_ALL)
CFLAGS_TS += $(CFLAGS_ALL)
CFLAGS_TQL_BUILD_TS_DEFS := $(foreach lang,$(shell echo '$(TS_LANGS)' | tr '[:lower:]' '[:upper:]'),-DTQL_BUILD_TS_$(lang))
ifeq ($(BUILD),debug)
	CFLAGS += $(CFLAGS_DEBUG)
else ifeq ($(BUILD),release)
	CFLAGS += $(CFLAGS_RELEASE)
	CFLAGS_TS += $(CFLAGS_RELEASE)
else
	$(error Unknown BUILD type: $(BUILD))
endif

CFLAGS += $(shell pkg-config --cflags tree-sitter libpcre2-8)
LDFLAGS += $(shell pkg-config --libs tree-sitter libpcre2-8)
ARFLAGS := rcs

LIB_DIR := lib
BUILD_DIR := build
GRAMMAR_DIR := $(BUILD_DIR)/grammars
HEADERS := $(wildcard src/*.h)

SOEXT := so

TS_TQL := ../tree-sitter-tql
TS_TQL_OBJS := $(patsubst $(TS_TQL)/src/%.c,$(GRAMMAR_DIR)/tql/%.o,$(wildcard $(TS_TQL)/src/*.c))

TQL_OBJS := $(patsubst $(LIB_DIR)/%.c,$(BUILD_DIR)/%.o,$(wildcard $(LIB_DIR)/*.c))
TS_OBJS := $(foreach lang,$(TS_LANGS), $(patsubst $($(shell echo TS_$(lang) | tr '[:lower:]' '[:upper:]'))/src/%.c, $(GRAMMAR_DIR)/$(lang)/%.o, $(wildcard $($(shell echo TS_$(lang) | tr '[:lower:]' '[:upper:]'))/src/*.c)))
OBJS := $(TQL_OBJS) $(TS_TQL_OBJS) $(TS_OBJS)

all: test tql-cli libtql.a libtql.$(SOEXT)

libtql.a: $(OBJS)
	$(AR) $(ARFLAGS) $@ $^

libtql.$(SOEXT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -shared $^ $(LDLIBS) -o $@

tql-cli: $(OBJS) cli/main.c
	$(CC) $(CFLAGS) -Ilib $(LDFLAGS) $^ -o $@

test: $(OBJS)
	$(CC) $(CFLAGS) -I. $(LDFLAGS) $(OBJS) tests/test.c -o $@
	./test

$(TQL_OBJS): $(HEADERS)

$(BUILD_DIR)/%.o: $(LIB_DIR)/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS) $(CFLAGS_TQL_BUILD_TS_DEFS) -c $< -o $@

$(GRAMMAR_DIR)/bash/%.o: $(TS_BASH)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_BASH)/src -c $< -o $@

$(GRAMMAR_DIR)/c/%.o: $(TS_C)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_C)/src -c $< -o $@

$(GRAMMAR_DIR)/cpp/%.o: $(TS_CPP)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_CPP)/src -c $< -o $@

$(GRAMMAR_DIR)/css/%.o: $(TS_CSS)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_CSS)/src -c $< -o $@

$(GRAMMAR_DIR)/go/%.o: $(TS_GO)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_GO)/src -c $< -o $@

$(GRAMMAR_DIR)/haskell/%.o: $(TS_HASKELL)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_HASKELL)/src -c $< -o $@

$(GRAMMAR_DIR)/java/%.o: $(TS_JAVA)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_JAVA)/src -c $< -o $@

$(GRAMMAR_DIR)/javascript/%.o: $(TS_JAVASCRIPT)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_JAVASCRIPT)/src -c $< -o $@

$(GRAMMAR_DIR)/json/%.o: $(TS_JSON)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_JSON)/src -c $< -o $@

$(GRAMMAR_DIR)/python/%.o: $(TS_PYTHON)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_PYTHON)/src -c $< -o $@

$(GRAMMAR_DIR)/rust/%.o: $(TS_RUST)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_RUST)/src -c $< -o $@

$(GRAMMAR_DIR)/tsx/%.o: $(TS_TSX)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_TSX)/src -c $< -o $@

$(GRAMMAR_DIR)/typescript/%.o: $(TS_TYPESCRIPT)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_TYPESCRIPT)/src -c $< -o $@

$(GRAMMAR_DIR)/tql/%.o: $(TS_TQL)/src/%.c
	mkdir -p $(@D)
	$(CC) $(CFLAGS_TS) -I$(TS_TQL)/src -c $< -o $@

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all clean test
