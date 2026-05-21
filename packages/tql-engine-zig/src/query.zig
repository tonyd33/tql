const std = @import("std");
const ts = @import("tree-sitter");

const runtime = @import("runtime.zig");
const pcre2 = @import("pcre2.zig");

const Language = @import("language.zig").Language;
const Allocator = std.mem.Allocator;
const ProgramImage = @import("runtime/program_image.zig").ProgramImage;

// Mirror a ts.Node. We want this to have its own lifetime independent of the tree sitter AST
// that backs a ts.Node.
pub const Node = struct {
    kind: []const u8,
    text: []const u8,
    start_byte: u32,
    end_byte: u32,
    start_point: runtime.Point,
    end_point: runtime.Point,
    child_count: u32,
    named_child_count: u32,
    is_named: bool,
    is_missing: bool,
    is_extra: bool,

    pub fn fromTsNode(gpa: Allocator, ts_node: ts.Node, source: []const u8) error{OutOfMemory}!Node {
        const start_point = ts_node.startPoint();
        const end_point = ts_node.endPoint();
        const kind = try gpa.dupe(u8, ts_node.kind());
        errdefer gpa.free(kind);
        const text = try gpa.dupe(u8, source[ts_node.startByte()..ts_node.endByte()]);
        return Node{
            .kind = kind,
            .text = text,
            .start_byte = ts_node.startByte(),
            .end_byte = ts_node.endByte(),
            .start_point = .{ .row = start_point.row, .column = start_point.column },
            .end_point = .{ .row = end_point.row, .column = end_point.column },
            .child_count = ts_node.childCount(),
            .named_child_count = ts_node.namedChildCount(),
            .is_named = ts_node.isNamed(),
            .is_missing = ts_node.isMissing(),
            .is_extra = ts_node.isExtra(),
        };
    }

    pub fn deinit(self: *Node, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.text);
    }
};

pub const Value = union(enum) {
    nothing: void,
    string: []const u8,
    uint: u64,
    node: Node,
    range: runtime.Range,
    record: Record,
    list: List,

    pub fn fromRuntimeValue(gpa: Allocator, val: runtime.Value, source: []const u8) error{OutOfMemory}!Value {
        return switch (val) {
            .nothing => .{ .nothing = {} },
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            .node => |n| .{ .node = try Node.fromTsNode(gpa, n, source) },
            .range => |r| .{ .range = r },
            .record => |rc| .{ .record = try Record.fromRuntime(gpa, &rc.value, source) },
            .list => |rc| .{ .list = try List.fromRuntime(gpa, &rc.value, source) },
            .uint => |u| .{ .uint = u },
            .kind_id, .field_id, .regex => @panic("TODO"),
        };
    }

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .node => |*n| n.deinit(gpa),
            .record => |*r| r.deinit(gpa),
            .list => |*l| l.deinit(gpa),
            else => {},
        }
    }

    pub fn jsonStringify(self: Value, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .nothing => try jws.write(null),
            .string => |s| try jws.write(s),
            .node => |n| try jws.write(n),
            .range => |r| try jws.write(r),
            .record => |r| try r.jsonStringify(jws),
            .list => |l| try l.jsonStringify(jws),
            .uint => |u| try jws.write(u),
        }
    }
};

pub const RecordEntry = struct {
    key: []const u8,
    value: Value,
};

pub const Record = struct {
    entries: []RecordEntry,

    pub fn fromRuntime(gpa: Allocator, src: *const runtime.Record, source: []const u8) error{OutOfMemory}!Record {
        const entries = try gpa.alloc(RecordEntry, src.map.count());
        errdefer gpa.free(entries);

        var it = src.map.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            entries[i] = .{
                .key = try gpa.dupe(u8, e.key_ptr.*),
                .value = try Value.fromRuntimeValue(gpa, e.value_ptr.*, source),
            };
        }
        std.mem.sort(RecordEntry, entries, {}, lessThanEntry);
        return .{ .entries = entries };
    }

    pub fn deinit(self: *Record, gpa: Allocator) void {
        for (self.entries) |*e| {
            gpa.free(e.key);
            e.value.deinit(gpa);
        }
        gpa.free(self.entries);
    }

    pub fn jsonStringify(self: Record, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        try jws.beginObject();
        for (self.entries) |e| {
            try jws.objectField(e.key);
            try e.value.jsonStringify(jws);
        }
        try jws.endObject();
    }

    fn lessThanEntry(_: void, a: RecordEntry, b: RecordEntry) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

pub const List = struct {
    items: []Value,

    pub fn fromRuntime(gpa: Allocator, src: *const runtime.List, source: []const u8) error{OutOfMemory}!List {
        const items = try gpa.alloc(Value, src.items.items.len);
        errdefer gpa.free(items);
        for (src.items.items, 0..) |v, i| items[i] = try Value.fromRuntimeValue(gpa, v, source);
        return .{ .items = items };
    }

    pub fn deinit(self: *List, gpa: Allocator) void {
        for (self.items) |*v| v.deinit(gpa);
        gpa.free(self.items);
    }

    pub fn jsonStringify(self: List, jws: *std.json.Stringify) std.json.Stringify.Error!void {
        try jws.beginArray();
        for (self.items) |v| try v.jsonStringify(jws);
        try jws.endArray();
    }
};

pub const QueryStats = struct {
    parse_time_us: u64 = 0,
    execute_time_us: u64 = 0,
};

pub const QueryResult = struct {
    values: []Value,
    stats: QueryStats,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.values) |*v| v.deinit(self.allocator);
        self.allocator.free(self.values);
    }
};

pub const Query = struct {
    program_image: *ProgramImage,
    language: Language,
    stats: QueryStats = .{},
    rt: ?runtime.Runtime = null,
    source_tree: *ts.Tree,
    source_code: []const u8,
    allocator: Allocator,

    /// Borrow ProgramImage.
    pub fn init(
        program_image: *ProgramImage,
        language: Language,
        source_code: []const u8,
        source_tree: *ts.Tree,
        allocator: Allocator,
    ) Query {
        return .{
            .program_image = program_image,
            .language = language,
            .source_code = source_code,
            .source_tree = source_tree,
            .allocator = allocator,
        };
    }

    pub fn exec(self: *Query) !void {
        self.rt = runtime.Runtime.init(.{
            .tree = self.source_tree,
            .source = self.source_code,
            .instructions = self.program_image.instructions,
            .regexes = self.program_image.regexes,
            .allocator = self.allocator,
        });

        try self.rt.?.exec();
    }

    /// Materializes the next match into `gpa`. Caller owns the returned Value
    /// and must call `Value.deinit(gpa)` on it. Strings/nodes are deep-copied so
    /// the result survives `Query.deinit` and the source tree.
    pub fn next(self: *Query, gpa: Allocator) !?Value {
        if (try self.rt.?.nextMatch()) |runtime_value| {
            return try Value.fromRuntimeValue(
                gpa,
                runtime_value,
                self.source_code,
            );
        } else {
            return null;
        }
    }

    pub fn deinit(self: *Query) void {
        self.rt.?.deinit();
    }
};
