package tree_sitter_tql_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_tql "github.com/tree-sitter/tree-sitter-tql/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_tql.Language())
	if language == nil {
		t.Errorf("Error loading Tql grammar")
	}
}
