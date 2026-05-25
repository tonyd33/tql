const std = @import("std");
const ts = @import("tree-sitter");

// IMPROVE: There's gotat be some comptime stuff we can do to toggle on different builds
pub const Language = enum {
    cpp,
    c,
    go,
    javascript,
    python,
    rust,
    tsx,
    typescript,
    zig,

    pub fn getTreeSitterLanguage(self: Language) *ts.Language {
        return switch (self) {
            .cpp =>tree_sitter_cpp(),
            .c => tree_sitter_c(),
            .go => tree_sitter_go(),
            .javascript => tree_sitter_javascript(),
            .python => tree_sitter_python(),
            .rust => tree_sitter_rust(),
            .tsx => tree_sitter_tsx(),
            .typescript => tree_sitter_typescript(),
            .zig => tree_sitter_zig(),
        };
    }

    pub fn name(self: Language) []const u8 {
        return switch (self) {
            .cpp => "cpp",
            .c => "c",
            .go => "go",
            .javascript => "javascript",
            .python => "python",
            .rust => "rust",
            .tsx => "tsx",
            .typescript => "typescript",
            .zig => "zig",
        };
    }
};

extern fn tree_sitter_cpp() *ts.Language;
extern fn tree_sitter_c() *ts.Language;
extern fn tree_sitter_go() *ts.Language;
extern fn tree_sitter_javascript() *ts.Language;
extern fn tree_sitter_python() *ts.Language;
extern fn tree_sitter_rust() *ts.Language;
extern fn tree_sitter_tsx() *ts.Language;
extern fn tree_sitter_typescript() *ts.Language;
extern fn tree_sitter_zig() *ts.Language;
