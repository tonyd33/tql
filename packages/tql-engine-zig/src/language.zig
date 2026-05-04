const std = @import("std");
const ts = @import("tree-sitter");

// IMPROVE: There's gotat be some comptime stuff we can do to toggle on different builds
pub const Language = enum {
    c,
    typescript,
    tsx,

    pub fn getTreeSitterLanguage(self: Language) *ts.Language {
        return switch (self) {
            .c => tree_sitter_c(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
        };
    }

    pub fn fromPath(path: []const u8) ?Language {
        if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
        if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
        if (std.mem.endsWith(u8, path, ".c")) return .c;
        if (std.mem.endsWith(u8, path, ".h")) return .c;
        return null;
    }

    pub fn name(self: Language) []const u8 {
        return switch (self) {
            .c => "c",
            .typescript => "typescript",
            .tsx => "tsx",
        };
    }
};

extern fn tree_sitter_c() *ts.Language;
extern fn tree_sitter_typescript() *ts.Language;
extern fn tree_sitter_tsx() *ts.Language;
