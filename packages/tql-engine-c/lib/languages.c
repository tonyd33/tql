#include "languages.h"
#include <string.h>

typedef const TSLanguage *(*TSLanguageFn)(void);
typedef struct {
  const char *name;
  TSLanguageFn get;
} LanguageEntry;

const TSLanguage *tree_sitter_tql(void);
#ifdef TQL_BUILD_TS_BASH
const TSLanguage *tree_sitter_bash(void);
#endif
#ifdef TQL_BUILD_TS_C
const TSLanguage *tree_sitter_c(void);
#endif
#ifdef TQL_BUILD_TS_CPP
const TSLanguage *tree_sitter_cpp(void);
#endif
#ifdef TQL_BUILD_TS_CSS
const TSLanguage *tree_sitter_css(void);
#endif
#ifdef TQL_BUILD_TS_GO
const TSLanguage *tree_sitter_go(void);
#endif
#ifdef TQL_BUILD_TS_HASKELL
const TSLanguage *tree_sitter_haskell(void);
#endif
#ifdef TQL_BUILD_TS_JAVA
const TSLanguage *tree_sitter_java(void);
#endif
#ifdef TQL_BUILD_TS_JAVASCRIPT
const TSLanguage *tree_sitter_javascript(void);
#endif
#ifdef TQL_BUILD_TS_PYTHON
const TSLanguage *tree_sitter_python(void);
#endif
#ifdef TQL_BUILD_TS_RUST
const TSLanguage *tree_sitter_rust(void);
#endif
#ifdef TQL_BUILD_TS_TSX
const TSLanguage *tree_sitter_tsx(void);
#endif
#ifdef TQL_BUILD_TS_TYPESCRIPT
const TSLanguage *tree_sitter_typescript(void);
#endif

static LanguageEntry LANGUAGE_ENTRIES[] = {
    {
        "tql",
        tree_sitter_tql,
    },
#ifdef TQL_BUILD_TS_BASH
    {
        "bash",
        tree_sitter_bash,
    },
#endif
#ifdef TQL_BUILD_TS_C
    {
        "c",
        tree_sitter_c,
    },
#endif
#ifdef TQL_BUILD_TS_CPP
    {
        "cpp",
        tree_sitter_cpp,
    },
#endif
#ifdef TQL_BUILD_TS_CSS
    {
        "css",
        tree_sitter_css,
    },
#endif
#ifdef TQL_BUILD_TS_GO
    {
        "go",
        tree_sitter_go,
    },
#endif
#ifdef TQL_BUILD_TS_HASKELL
    {
        "haskell",
        tree_sitter_haskell,
    },
#endif
#ifdef TQL_BUILD_TS_JAVA
    {
        "java",
        tree_sitter_java,
    },
#endif
#ifdef TQL_BUILD_TS_JAVASCRIPT
    {
        "javascript",
        tree_sitter_javascript,
    },
#endif
#ifdef TQL_BUILD_TS_PYTHON
    {
        "python",
        tree_sitter_python,
    },
#endif
#ifdef TQL_BUILD_TS_RUST
    {
        "rust",
        tree_sitter_rust,
    },
#endif
#ifdef TQL_BUILD_TS_TSX
    {
        "tsx",
        tree_sitter_tsx,
    },
#endif
#ifdef TQL_BUILD_TS_TYPESCRIPT
    {
        "typescript",
        tree_sitter_typescript,
    },
#endif
};

const TSLanguage *ts_language_for_name(const char *language, size_t length) {
  for (unsigned long j = 0;
       j < sizeof(LANGUAGE_ENTRIES) / sizeof(LanguageEntry); j++) {
    if (strncmp(language, LANGUAGE_ENTRIES[j].name, length) == 0) {
      return LANGUAGE_ENTRIES[j].get();
    }
  }
  return NULL;
}
