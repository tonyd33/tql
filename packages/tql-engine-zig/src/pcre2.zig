const re = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});
const PCRE2_ZERO_TERMINATED = ~@as(re.PCRE2_SIZE, 0);
const std = @import("std");

const PCRE2Error = error{PCRE2Unknown};

pub const Regex = struct {
    const Self = @This();

    regex: *re.pcre2_code_8,

    pub fn eql(self: Self, other: Self) bool {
        return self.regex == other.regex;
    }

    pub fn compile(needle: []const u8) !Self {
        const pattern: re.PCRE2_SPTR8 = &needle[0];
        var errornumber: c_int = undefined;
        var erroroffset: re.PCRE2_SIZE = undefined;

        const maybe_regex: ?*re.pcre2_code_8 = re.pcre2_compile_8(pattern, PCRE2_ZERO_TERMINATED, 0, &errornumber, &erroroffset, null);

        // IMPROVE: Better error
        return if (maybe_regex) |regex| Self{ .regex = regex } else error.PCRE2Unknown;
    }

    pub fn deinit(self: *Self) void {
        re.pcre2_code_free_8(self.regex);
    }

    pub fn do_test(self: *const Self, haystack: []const u8) bool {
        var matches = self.match(haystack) catch {
            return false;
        };
        defer matches.deinit();

        return matches.rc > 0;
    }

    pub fn match(self: *const Self, haystack: []const u8) !RegexSearch {
        const subject: re.PCRE2_SPTR8 = &haystack[0];
        const subj_len: re.PCRE2_SIZE = haystack.len;

        const match_data = re.pcre2_match_data_create_from_pattern_8(self.regex, null);
        errdefer re.pcre2_match_data_free_8(match_data);
        const rc = re.pcre2_match_8(self.regex, subject, subj_len, 0, 0, match_data.?, null);

        if (rc < 0) {
            // IMPROVE: Better error
            return error.PCRE2Unknown;
        }

        const ovector = re.pcre2_get_ovector_pointer_8(match_data);
        if (rc == 0) {
            std.debug.print("ovector was not big enough for all the captured substrings\n", .{});
            // IMPROVE: Better error
            return error.PCRE2Unknown;
        }

        if (ovector[0] > ovector[1]) {
            std.debug.print("error with ovector\n", .{});
            // IMPROVE: Better error
            return error.PCRE2Unknown;
        }

        return RegexSearch{
            .haystack = haystack,
            .match_data = match_data.?,
            .i = 0,
            .rc = rc,
            .ovector = ovector,
        };
    }
};

pub const RegexSearch = struct {
    const Self = @This();

    haystack: []const u8,
    match_data: *re.pcre2_match_data_8,
    i: u16,
    rc: c_int,
    ovector: [*c]usize,

    pub fn deinit(self: *Self) void {
        re.pcre2_match_data_free_8(self.match_data);
    }

    pub fn next(self: *Self) ?[]const u8 {
        if (self.i < self.rc) {
            const start = self.ovector[2 * self.i];
            const end = self.ovector[2 * self.i + 1];
            self.i += 1;
            return self.haystack[start..end];
        } else {
            return null;
        }
    }
};

const expect = std.testing.expect;

test "sanity" {
    const pattern = "your\\s(.*)\\s";
    const subject = "all of your codebase are belong to us!";
    var regex = try Regex.compile(pattern);
    defer regex.deinit();
    var matches = try regex.match(subject);
    defer matches.deinit();

    var match = matches.next() orelse @panic("failed");
    try expect(std.mem.eql(u8, match, "your codebase are belong to "));

    match = matches.next() orelse @panic("failed");
    try expect(std.mem.eql(u8, match, "codebase are belong to"));
}
