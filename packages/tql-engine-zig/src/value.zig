const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Point = struct {
    row: u32,
    column: u32,
};

// NOTE: Consider trimming, this is a pretty huge struct
pub const Range = struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const NodeSnapshot = struct {
    kind: []const u8,
    text: []const u8,
    start_byte: u32,
    end_byte: u32,
    start_point: Point,
    end_point: Point,

    pub fn deinit(self: *NodeSnapshot, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.text);
    }
};

pub const RecordEntry = struct {
    key: []const u8,
    value: Value,
};

pub const RecordView = struct {
    _entries: []RecordEntry,

    pub fn count(self: RecordView) usize {
        return self._entries.len;
    }

    pub fn get(self: RecordView, key: []const u8) ?*const Value {
        for (self._entries) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.value;
        }
        return null;
    }

    pub fn iterator(self: RecordView) RecordIterator {
        return .{ ._entries = self._entries, ._i = 0 };
    }
};

pub const RecordIterator = struct {
    _entries: []RecordEntry,
    _i: usize,

    pub fn next(self: *RecordIterator) ?RecordEntry {
        if (self._i >= self._entries.len) return null;
        const e = self._entries[self._i];
        self._i += 1;
        return e;
    }
};

pub const ListView = struct {
    _items: []Value,

    pub fn len(self: ListView) usize {
        return self._items.len;
    }

    pub fn get(self: ListView, i: usize) Value {
        return self._items[i];
    }

    pub fn items(self: ListView) []const Value {
        return self._items;
    }
};

/// Public value type. Callers can switch on this directly.
/// All data is owned. Safe to keep after Query.run() returns.
/// Call deinit() when done.
pub const Value = union(enum) {
    nothing,
    bool: bool,
    int: i64,
    string: []const u8,
    range: Range,
    node: NodeSnapshot,
    record: RecordView,
    list: ListView,

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .node => |*n| n.deinit(gpa),
            .record => |rv| {
                for (rv._entries) |*e| {
                    gpa.free(e.key);
                    e.value.deinit(gpa);
                }
                gpa.free(rv._entries);
            },
            .list => |lv| {
                for (lv._items) |*v| v.deinit(gpa);
                gpa.free(lv._items);
            },
            else => {},
        }
    }

    pub fn toString(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // FIXME: should print on a single line
        switch (self) {
            .nothing => try writer.writeAll("nothing"),
            .bool => |b| try writer.print("{}", .{b}),
            .int => |i| try writer.print("{d}", .{i}),
            .string => |s| try writer.writeAll(s),
            .range => |r| try writer.print("{d}:{d}-{d}:{d}", .{ r.start_point.row, r.start_point.column, r.end_point.row, r.end_point.column }),
            .node => |n| try writer.print("{s} [{d}:{d}-{d}:{d}]", .{ n.kind, n.start_point.row, n.start_point.column, n.end_point.row, n.end_point.column }),
            .record => |rv| {
                try writer.writeByte('{');
                for (rv._entries, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}: ", .{e.key});
                    try e.value.toString(writer);
                }
                try writer.writeByte('}');
            },
            .list => |lv| {
                try writer.writeByte('[');
                for (lv._items, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.toString(writer);
                }
                try writer.writeByte(']');
            },
        }
    }

    pub fn jsonStringify(self: Value, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .nothing => try jws.write(null),
            .bool => |b| try jws.write(b),
            .int => |i| try jws.write(i),
            .string => |s| try jws.write(s),
            .range => |r| try jws.write(r),
            .node => |n| try jws.write(n),
            .record => |rv| {
                try jws.beginObject();
                for (rv._entries) |e| {
                    try jws.objectField(e.key);
                    try e.value.jsonStringify(jws);
                }
                try jws.endObject();
            },
            .list => |lv| {
                try jws.beginArray();
                for (lv._items) |v| try v.jsonStringify(jws);
                try jws.endArray();
            },
        }
    }
};
