const std = @import("std");

pub const Decoded = union(enum) {
    bytes: []u8,
    /// The escape sequence at this byte offset is not one TQL defines.
    invalid_escape: usize,
};

/// Decode the body of a string literal, its delimiting quotes already
/// stripped. `\"`, `\\`, `\n`, `\t` and `\r` are the only escapes.
///
/// Preconditions:
/// - Every `\` in `body` is followed by another byte.
pub fn decode(allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error!Decoded {
    var out: std.ArrayList(u8) = try .initCapacity(allocator, body.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            out.appendAssumeCapacity(body[i]);
            continue;
        }
        const decoded: u8 = switch (body[i + 1]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => {
                out.deinit(allocator);
                return .{ .invalid_escape = i };
            },
        };
        out.appendAssumeCapacity(decoded);
        i += 1;
    }
    return .{ .bytes = try out.toOwnedSlice(allocator) };
}

/// Write `bytes` as the body of a string literal that decodes back to them.
pub fn escape(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (bytes) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(b),
    };
}

pub fn fmt(bytes: []const u8) std.fmt.Alt([]const u8, escape) {
    return .{ .data = bytes };
}
