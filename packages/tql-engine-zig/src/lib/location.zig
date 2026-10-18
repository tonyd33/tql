//! Positions and ranges in a source text, shared by the query's spans and
//! the target's nodes.

const std = @import("std");
const ts = @import("tree-sitter");

/// A position as a fixture writes it: zero-based internally, rendered
/// one-based. `column` counts bytes.
pub const Point = struct {
    row: u32,
    column: u32,

    pub fn format(self: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.row + 1, self.column + 1 });
    }
};

/// A source range, half-open in bytes: `[start_byte, end_byte)`.
///
/// Points are carried alongside the byte offsets because error fixtures pin
/// `line:col`, and recovering that from a byte offset alone would mean
/// re-scanning the source at every diagnostic.
pub const Range = struct {
    start_byte: u32,
    end_byte: u32,
    start_point: Point,
    end_point: Point,

    /// The range `node` covers.
    pub fn ofNode(node: ts.Node) Range {
        const r = node.range();
        return .{
            .start_byte = r.start_byte,
            .end_byte = r.end_byte,
            .start_point = .{ .row = r.start_point.row, .column = r.start_point.column },
            .end_point = .{ .row = r.end_point.row, .column = r.end_point.column },
        };
    }

    /// Write the fields, in the order the public encoding fixes, into an
    /// object the caller has begun.
    pub fn jsonFields(self: Range, jws: anytype) !void {
        try jws.objectField("start_byte");
        try jws.write(self.start_byte);
        try jws.objectField("end_byte");
        try jws.write(self.end_byte);
        try jws.objectField("start_point");
        try jws.write(self.start_point);
        try jws.objectField("end_point");
        try jws.write(self.end_point);
    }

    /// The `line:col-line:col` form the error fixtures are written in.
    pub fn format(self: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.start_point.format(w);
        try w.writeByte('-');
        try self.end_point.format(w);
    }

    /// Byte offsets only, for the AST s-expression goldens.
    pub fn sexpr(self: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.start_byte, self.end_byte });
    }

    /// The smallest range covering both operands.
    pub fn join(a: Range, b: Range) Range {
        const start_first = a.start_byte <= b.start_byte;
        const end_first = a.end_byte >= b.end_byte;
        return .{
            .start_byte = if (start_first) a.start_byte else b.start_byte,
            .end_byte = if (end_first) a.end_byte else b.end_byte,
            .start_point = if (start_first) a.start_point else b.start_point,
            .end_point = if (end_first) a.end_point else b.end_point,
        };
    }
};
