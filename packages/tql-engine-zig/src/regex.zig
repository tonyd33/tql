const re = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const Regex = struct {
    const Self = @This();

    regex: *re.pcre2_code_8,

    pub fn eql(self: Self, other: Self) bool {
        return self.regex == other.regex;
    }

    pub fn compile(needle: []const u8) !Self {
        const pattern: re.PCRE2_SPTR8 = needle.ptr;
        var errornumber: c_int = undefined;
        var erroroffset: re.PCRE2_SIZE = undefined;

        const maybe_regex: ?*re.pcre2_code_8 = re.pcre2_compile_8(pattern, needle.len, 0, &errornumber, &erroroffset, null);

        // IMPROVE: Better error
        return if (maybe_regex) |regex| Self{ .regex = regex } else error.PCRE2Unknown;
    }

    pub fn deinit(self: *Self) void {
        re.pcre2_code_free_8(self.regex);
    }

    /// Whether `haystack` contains a match, using `scratch` instead of
    /// allocating.
    pub fn isMatch(self: *const Self, haystack: []const u8, scratch: *MatchData) bool {
        const rc = re.pcre2_match_8(self.regex, haystack.ptr, haystack.len, 0, 0, scratch.data, null);
        // Zero means a match whose groups did not all fit the one-pair
        // ovector.
        return rc >= 0;
    }
};

/// Match scratch for `Regex.isMatch`, reusable across patterns and calls.
/// Not safe to share between threads.
pub const MatchData = struct {
    data: *re.pcre2_match_data_8,

    pub fn create() error{OutOfMemory}!MatchData {
        // One pair: a test reads only whether there was a match.
        const data = re.pcre2_match_data_create_8(1, null) orelse return error.OutOfMemory;
        return .{ .data = data };
    }

    pub fn deinit(self: *MatchData) void {
        re.pcre2_match_data_free_8(self.data);
    }
};
