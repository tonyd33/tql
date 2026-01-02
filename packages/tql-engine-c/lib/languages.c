#include "languages.h"
#include <string.h>

typedef const TSLanguage *(*TSLanguageFn)(void);
typedef struct {
  const char *name;
  TSLanguageFn get;
} LanguageEntry;

const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_haskell(void);
const TSLanguage *tree_sitter_java(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_typescript(void);

static LanguageEntry LANGUAGE_ENTRIES[] = {
    {
        "bash",
        tree_sitter_bash,
    },
    {
        "c",
        tree_sitter_c,
    },
    {
        "cpp",
        tree_sitter_cpp,
    },
    {
        "css",
        tree_sitter_css,
    },
    {
        "go",
        tree_sitter_go,
    },
    {
        "haskell",
        tree_sitter_haskell,
    },
    {
        "java",
        tree_sitter_java,
    },
    {
        "javascript",
        tree_sitter_javascript,
    },
    {
        "python",
        tree_sitter_python,
    },
    {
        "rust",
        tree_sitter_rust,
    },
    {
        "typescript",
        tree_sitter_typescript,
    },
};

const TSLanguage *ts_language_for_name(const char *language, size_t length) {
  for (unsigned long j = 0; j < sizeof(LANGUAGE_ENTRIES) / sizeof(LanguageEntry); j++) {
    if (strncmp(language, LANGUAGE_ENTRIES[j].name, length) == 0) {
      return LANGUAGE_ENTRIES[j].get();
    }
  }
  return NULL;
}
