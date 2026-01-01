#ifndef _LANGUAGES_H_
#define _LANGUAGES_H_
#include <tree_sitter/api.h>

const TSLanguage *ts_language_for_name(const char *language, size_t length);

#endif /* _LANGUAGES_H_ */
