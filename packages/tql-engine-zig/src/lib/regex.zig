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

    pub fn compile(needle: []const u8) error{ InvalidPattern, Backreference }!Self {
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
    /// allocating where it can. An ill-formed UTF-8 sequence in `haystack`
    /// matches as U+FFFD.
    ///
    /// Fails with `RegexFailed` only for a construct the DFA matcher rejects
    /// when it reaches it, such as `\K` or a backtracking verb.
    pub fn isMatch(self: *const Self, haystack: []const u8, scratch: *MatchData) error{ OutOfMemory, RegexFailed }!bool {
        const subject = if (std.unicode.utf8ValidateSlice(haystack)) haystack else blk: {
            scratch.decoded.clearRetainingCapacity();
            scratch.decoded.writer.print("{f}", .{std.unicode.fmtUtf8(haystack)}) catch return error.OutOfMemory;
            break :blk scratch.decoded.written();
        };
        while (true) {
            const rc = re.pcre2_dfa_match_8(
                self.regex,
                subject.ptr,
                subject.len,
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

/// Match scratch for `Regex.isMatch`, reusable across patterns and calls.
/// Not safe to share between threads.
pub const MatchData = struct {
    gpa: std.mem.Allocator,
    data: *re.pcre2_match_data_8,
    context: *re.pcre2_match_context_8,
    /// The DFA matcher's state vectors. Doubled whenever a pattern needs more.
    workspace: []c_int,
    /// The subject with each ill-formed UTF-8 sequence replaced by U+FFFD.
    decoded: std.Io.Writer.Allocating,

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
            .decoded = .init(gpa),
        };
    }

    fn growWorkspace(self: *MatchData) error{OutOfMemory}!void {
        const bigger = try self.gpa.alloc(c_int, self.workspace.len * 2);
        self.gpa.free(self.workspace);
        self.workspace = bigger;
    }

    pub fn deinit(self: *MatchData) void {
        self.decoded.deinit();
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

test "an ill-formed sequence matches as one replacement character" {
    var regex = try Regex.compile("^a\u{FFFD}b$");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try regex.isMatch("a\xe2\x82b", &scratch));
    try std.testing.expect(!try regex.isMatch("a\xffb\xff", &scratch));
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

test "a construct the matcher cannot run fails the match" {
    var regex = try Regex.compile("a\\Kb");
    defer regex.deinit();
    var scratch = try MatchData.create(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.RegexFailed, regex.isMatch("ab", &scratch));
}
