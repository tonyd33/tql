const std = @import("std");

const re = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

/// A pattern matched over UTF-8 code points, with ASCII `\d`, `\w` and `\s`,
/// by an engine that never backtracks.
pub const Regex = struct {
    const Self = @This();

    regex: *re.pcre2_code_8,

    pub fn eql(self: Self, other: Self) bool {
        return self.regex == other.regex;
    }

    /// Fails with `Unsupported` on a construct `unsupported` names.
    pub fn compile(needle: []const u8) error{ InvalidPattern, Backreference, Unsupported }!Self {
        if (unsupported(needle) != null) return error.Unsupported;
        const pattern: re.PCRE2_SPTR8 = needle.ptr;
        var errornumber: c_int = undefined;
        var erroroffset: re.PCRE2_SIZE = undefined;

        const regex = re.pcre2_compile_8(
            pattern,
            needle.len,
            re.PCRE2_UTF | re.PCRE2_NEVER_BACKSLASH_C,
            &errornumber,
            &erroroffset,
            null,
        ) orelse return error.InvalidPattern;
        errdefer re.pcre2_code_free_8(regex);

        // The DFA matcher keeps no captures, so it cannot follow a
        // backreference.
        var backrefs: u32 = 0;
        if (re.pcre2_pattern_info_8(regex, re.PCRE2_INFO_BACKREFMAX, &backrefs) != 0) return error.InvalidPattern;
        if (backrefs > 0) return error.Backreference;

        return .{ .regex = regex };
    }

    pub fn deinit(self: *Self) void {
        re.pcre2_code_free_8(self.regex);
    }

    /// Whether `haystack` contains a match, using `scratch` instead of
    /// allocating where it can.
    ///
    /// Fails with `RegexFailed` only for a construct the DFA matcher rejects
    /// when it reaches it and `unsupported` lets through: a recursion that
    /// consumes nothing before recursing.
    ///
    /// Preconditions:
    /// - `haystack` is well-formed UTF-8. Every string the machine holds is:
    ///   the parser rejects an ill-formed literal, and `text` and `filename`
    ///   decode what they read.
    pub fn isMatch(self: *const Self, haystack: []const u8, scratch: *MatchData) error{ OutOfMemory, RegexFailed }!bool {
        while (true) {
            const rc = re.pcre2_dfa_match_8(
                self.regex,
                haystack.ptr,
                haystack.len,
                0,
                re.PCRE2_DFA_SHORTEST | re.PCRE2_NO_UTF_CHECK,
                scratch.data,
                scratch.context,
                scratch.workspace.ptr,
                scratch.workspace.len,
            );
            // Zero means a match whose offsets did not all fit the one-pair
            // ovector.
            if (rc >= 0) return true;
            switch (rc) {
                re.PCRE2_ERROR_NOMATCH => return false,
                re.PCRE2_ERROR_NOMEMORY => return error.OutOfMemory,
                re.PCRE2_ERROR_DFA_WSSIZE => try scratch.growWorkspace(),
                else => return error.RegexFailed,
            }
        }
    }
};

/// Returns the first construct in `pattern` that the DFA matcher fails on
/// when a match reaches it, or that makes `\d`, `\w` and `\s` Unicode:
/// `\K`, a backtracking verb, a script run, or `(*UCP)`. The slice runs to
/// the verb's `)` or `:`.
///
/// A `#` comment under `(?x)` is scanned as pattern.
pub fn unsupported(pattern: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '\\' => {
                if (i + 1 >= pattern.len) return null;
                switch (pattern[i + 1]) {
                    'K' => return pattern[i .. i + 2],
                    'Q' => i = endOfQuote(pattern, i + 2),
                    else => i += 2,
                }
            },
            '[' => i = endOfClass(pattern, i + 1),
            '(' => {
                const rest = pattern[i + 1 ..];
                if (std.mem.startsWith(u8, rest, "?#")) {
                    i = if (std.mem.indexOfScalarPos(u8, pattern, i, ')')) |close| close + 1 else pattern.len;
                } else if (std.mem.startsWith(u8, rest, "*")) {
                    const name_start = i + 2;
                    const name_end = std.mem.indexOfAnyPos(u8, pattern, name_start, ":)") orelse return null;
                    const name = pattern[name_start..name_end];
                    for (verbs) |verb| {
                        if (std.mem.eql(u8, name, verb)) return pattern[i .. name_end + 1];
                    }
                    i = name_end + 1;
                } else i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// The `(*NAME` items `unsupported` rejects. The empty name is `(*:NAME)`,
/// short for `(*MARK:NAME)`.
const verbs = [_][]const u8{
    "ACCEPT",
    "COMMIT",
    "PRUNE",
    "SKIP",
    "THEN",
    "MARK",
    "",
    "sr",
    "script_run",
    "asr",
    "atomic_script_run",
    "UCP",
};

/// Returns the index after the `\E` closing a quote whose text starts at
/// `start`, or the pattern's end.
fn endOfQuote(pattern: []const u8, start: usize) usize {
    const close = std.mem.indexOfPos(u8, pattern, start, "\\E") orelse return pattern.len;
    return close + 2;
}

/// Returns the index after the `]` closing a class whose body starts at
/// `start`. A `]` first in the body, after an optional `^`, is literal.
fn endOfClass(pattern: []const u8, start: usize) usize {
    var i = start;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '\\' => i = if (std.mem.startsWith(u8, pattern[i..], "\\Q")) endOfQuote(pattern, i + 2) else i + 2,
            '[' => if (std.mem.startsWith(u8, pattern[i..], "[:")) {
                i = if (std.mem.indexOfPos(u8, pattern, i + 2, ":]")) |close| close + 2 else i + 1;
            } else {
                i += 1;
            },
            ']' => return i + 1,
            else => i += 1,
        }
    }
    return pattern.len;
}

/// Match scratch for `Regex.isMatch`, reusable across patterns and calls.
/// Not safe to share between threads.
pub const MatchData = struct {
    gpa: std.mem.Allocator,
    data: *re.pcre2_match_data_8,
    context: *re.pcre2_match_context_8,
    /// The DFA matcher's state vectors. Doubled whenever a pattern needs more.
    workspace: []c_int,

    pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!MatchData {
        // One pair: a test reads only whether there was a match.
        const data = re.pcre2_match_data_create_8(1, null) orelse return error.OutOfMemory;
        errdefer re.pcre2_match_data_free_8(data);
        const context = re.pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        errdefer re.pcre2_match_context_free_8(context);
        // The match limit bounds backtracking. Without backtracking it only
        // counts work that grows with the subject, so a long file would trip it.
        _ = re.pcre2_set_match_limit_8(context, std.math.maxInt(u32));
        return .{
            .gpa = gpa,
            .data = data,
            .context = context,
            .workspace = try gpa.alloc(c_int, 1024),
        };
    }

    fn growWorkspace(self: *MatchData) error{OutOfMemory}!void {
        const bigger = try self.gpa.alloc(c_int, self.workspace.len * 2);
        self.gpa.free(self.workspace);
        self.workspace = bigger;
    }

    pub fn deinit(self: *MatchData) void {
        self.gpa.free(self.workspace);
        re.pcre2_match_context_free_8(self.context);
        re.pcre2_match_data_free_8(self.data);
    }
};

test "a pattern that backtracks exponentially matches" {
    var regex = try Regex.compile("^(?:(a|aa)+b|a+c)$");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try regex.isMatch("a" ** 4096 ++ "c", &scratch));
    try std.testing.expect(!try regex.isMatch("a" ** 4096 ++ "d", &scratch));
}

test "a dot matches one code point" {
    var regex = try Regex.compile("^.$");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try regex.isMatch("é", &scratch));
    try std.testing.expect(!try regex.isMatch("e\u{301}", &scratch));
}

test "classes are ASCII" {
    var regex = try Regex.compile("^\\d$");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try regex.isMatch("7", &scratch));
    try std.testing.expect(!try regex.isMatch("\u{0667}", &scratch));
}

test "a backreference is rejected" {
    try std.testing.expectError(error.Backreference, Regex.compile("(a)\\1"));
}

test "a construct the matcher cannot run is rejected" {
    try std.testing.expectError(error.Unsupported, Regex.compile("a\\Kb|b"));
    try std.testing.expectEqualStrings("\\K", unsupported("a\\Kb|b").?);
    try std.testing.expectEqualStrings("(*PRUNE)", unsupported("a(*PRUNE)b").?);
    try std.testing.expectEqualStrings("(*MARK:", unsupported("a(*MARK:x)b").?);
    try std.testing.expectEqualStrings("(*:", unsupported("a(*:x)b").?);
    try std.testing.expectEqualStrings("(*sr:", unsupported("(*sr:ab)").?);
    try std.testing.expectEqualStrings("(*UCP)", unsupported("(*UCP)\\d").?);
}

test "a construct quoted, in a class or in a comment is not rejected" {
    try std.testing.expectEqual(null, unsupported("\\\\K"));
    try std.testing.expectEqual(null, unsupported("\\Qa\\K(*PRUNE)\\E"));
    try std.testing.expectEqual(null, unsupported("[]\\](*PRUNE)]"));
    try std.testing.expectEqual(null, unsupported("[[:alpha:]](*F)|a"));
    try std.testing.expectEqual(null, unsupported("(?#\\K)a"));
    try std.testing.expectEqual(null, unsupported("(*pla:a)(*atomic:a)(*UTF)(*FAIL)"));
}

test "a left recursion fails the match" {
    var regex = try Regex.compile("(?R)?b");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.RegexFailed, regex.isMatch("b", &scratch));
}
