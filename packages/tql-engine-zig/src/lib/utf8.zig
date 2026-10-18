//! Reading bytes as UTF-8, with each maximal ill-formed subpart replaced by
//! U+FFFD (Unicode 15, §3.9, "U+FFFD Substitution of Maximal Subparts").
//!
//! Every string written to a host is well-formed. Bytes reach a host from a
//! target file, as a node's text, and from the file system, as a path.

const std = @import("std");

const replacement = "\u{FFFD}";

/// A piece of the input: a run of well-formed UTF-8, or one maximal
/// ill-formed subpart, which reads as a single U+FFFD.
pub const Chunk = union(enum) {
    well_formed: []const u8,
    ill_formed: []const u8,
};

/// Split `bytes` into chunks, in order. Adjacent well-formed runs are merged.
pub const Chunks = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(self: *Chunks) ?Chunk {
        if (self.at >= self.bytes.len) return null;
        const start = self.at;
        const bad = illFormedLength(self.bytes[start..]);
        if (bad > 0) {
            self.at += bad;
            return .{ .ill_formed = self.bytes[start..self.at] };
        }
        while (self.at < self.bytes.len and illFormedLength(self.bytes[self.at..]) == 0) {
            self.at += std.unicode.utf8ByteSequenceLength(self.bytes[self.at]) catch unreachable;
        }
        return .{ .well_formed = self.bytes[start..self.at] };
    }
};

/// Returns 0 when `bytes` starts with a well-formed sequence. Otherwise
/// returns the length of the maximal subpart it starts with: the longest
/// prefix of some well-formed sequence, or one byte if there is none.
///
/// Preconditions:
/// - `bytes` is not empty.
fn illFormedLength(bytes: []const u8) usize {
    const lead = bytes[0];
    const needed: usize, const lo: u8, const hi: u8 = switch (lead) {
        0x00...0x7F => return 0,
        0xC2...0xDF => .{ 1, 0x80, 0xBF },
        0xE0 => .{ 2, 0xA0, 0xBF },
        0xED => .{ 2, 0x80, 0x9F },
        0xE1...0xEC, 0xEE...0xEF => .{ 2, 0x80, 0xBF },
        0xF0 => .{ 3, 0x90, 0xBF },
        0xF1...0xF3 => .{ 3, 0x80, 0xBF },
        0xF4 => .{ 3, 0x80, 0x8F },
        else => return 1,
    };
    for (1..needed + 1) |i| {
        if (i >= bytes.len) return i;
        const range_lo: u8, const range_hi: u8 = if (i == 1) .{ lo, hi } else .{ 0x80, 0xBF };
        if (bytes[i] < range_lo or bytes[i] > range_hi) return i;
    }
    return 0;
}

/// Returns `bytes` read as UTF-8. Borrows `bytes` when it is well-formed;
/// otherwise the result is allocated in `allocator`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunks: Chunks = .{ .bytes = bytes };
    while (chunks.next()) |chunk| switch (chunk) {
        .well_formed => |run| try out.appendSlice(allocator, run),
        .ill_formed => try out.appendSlice(allocator, replacement),
    };
    return out.toOwnedSlice(allocator);
}

/// Bytes a JSON writer encodes as a string, read as UTF-8. A plain
/// `[]const u8` that is ill-formed is written as an array of numbers.
pub const Lossy = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: Lossy, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        if (std.unicode.utf8ValidateSlice(self.bytes)) return jws.write(self.bytes);
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        var chunks: Chunks = .{ .bytes = self.bytes };
        while (chunks.next()) |chunk| {
            const text = switch (chunk) {
                .well_formed => |run| run,
                .ill_formed => replacement,
            };
            try std.json.Stringify.encodeJsonStringChars(text, jws.options, jws.writer);
        }
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }
};

test "each maximal subpart is one replacement character" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "caf\xe9", "caf\u{FFFD}" },
        .{ "a\xe2\x82b", "a\u{FFFD}b" },
        .{ "\xC0\xAF\xE0\x80\xBF\xF0\x81\x82A", "\u{FFFD}" ** 8 ++ "A" },
        .{ "\xED\xA0\x80\xED\xBF\xBF\xED\xAFA", "\u{FFFD}" ** 8 ++ "A" },
        .{ "\xF4\x91\x92\x93\xFFA\x80\xBFB", "\u{FFFD}" ** 5 ++ "A" ++ "\u{FFFD}" ** 2 ++ "B" },
        .{ "\xF0\x9F\x98", "\u{FFFD}" },
    };
    for (cases) |case| {
        const decoded = try decode(gpa, case[0]);
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(case[1], decoded);
    }
}

test "well-formed bytes are borrowed" {
    const bytes = "é𐐷";
    try std.testing.expectEqual(bytes.ptr, (try decode(std.testing.failing_allocator, bytes)).ptr);
}

test "lossy bytes are a JSON string" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    var jws: std.json.Stringify = .{ .writer = &w.writer };
    try jws.write(.{ .text = Lossy{ .bytes = "\"caf\xe9\"\n" } });
    try std.testing.expectEqualStrings("{\"text\":\"\\\"caf\u{FFFD}\\\"\\n\"}", w.written());
}
