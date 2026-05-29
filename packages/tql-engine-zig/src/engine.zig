const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const runtime = @import("runtime.zig");
const ast = @import("ast.zig");
const Language = @import("language.zig").Language;

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

pub const Config = struct {
    allocator: Allocator,
    // Do I really need this?
    io: std.Io,
};

pub const RunStats = struct {
    parse_time: std.Io.Duration,
    query_time: std.Io.Duration,
};

pub const RunResult = struct {
    values: std.ArrayList(Value),
    stats: RunStats,
    allocator: Allocator,

    pub fn deinit(self: *RunResult) void {
        for (self.values.items) |*v| v.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }
};

/// A "batteries-included" interface to the TQL primitives.
pub const Engine = struct {
    config: Config,
    tql_parser: parser.Parser,

    pub fn init(config: Config) !Engine {
        return Engine{
            .config = config,
            .tql_parser = try parser.Parser.init(config.allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.tql_parser.deinit();
    }

    // for debug
    pub fn parseQuery(self: *Engine, query_source: []const u8) !ast.SourceFile {
        return try self.tql_parser.parse(query_source);
    }

    /// Parse + compile a TQL query for a given target language.
    /// Returned CompiledQuery owns its ProgramImage.
    pub fn compile(self: *Engine, query_source: []const u8, language: Language) !Query {
        const source_file = try self.tql_parser.parse(query_source);
        defer source_file.deinit(self.config.allocator);

        var c = compiler.Compiler.init(self.config.allocator, language.getTreeSitterLanguage());
        defer c.deinit();

        const program_image = try c.compile(self.config.allocator, source_file);
        return .{
            .program_image = program_image,
            .language = language,
            .allocator = self.config.allocator,
            .io = self.config.io,
        };
    }
};

pub const Query = struct {
    program_image: runtime.ProgramImage,
    language: Language,
    allocator: Allocator,
    // Do I really want this...?
    io: std.Io,

    pub fn deinit(self: *Query) void {
        self.program_image.deinit();
    }

    pub fn instructions(self: *const Query) []const runtime.Instruction {
        return self.program_image.instructions;
    }

    /// Run against one in-memory query target buffer. Caller owns returned
    /// values (deep-copied into `result_allocator`). `query_target` must
    /// outlive the call but not the result.
    pub fn run(
        self: *Query,
        query_target: []const u8,
        result_allocator: Allocator,
        scratch_allocator: Allocator,
    ) !RunResult {
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();
        try source_parser.setLanguage(self.language.getTreeSitterLanguage());

        const parse_start = std.Io.Timestamp.now(self.io, .real);
        const tree = source_parser.parseString(query_target, null) orelse return error.SourceParseFailed;
        defer tree.destroy();
        const parse_time = parse_start.untilNow(self.io, .real);

        var rt = runtime.Runtime.init(.{
            .tree = tree,
            .source = query_target,
            .instructions = self.program_image.instructions,
            .regexes = self.program_image.regexes,
            .allocator = scratch_allocator,
        });
        try rt.exec();
        defer rt.deinit();

        var values: std.ArrayList(Value) = .empty;
        errdefer {
            for (values.items) |*v| v.deinit(result_allocator);
            values.deinit(result_allocator);
        }

        const query_start = std.Io.Timestamp.now(self.io, .real);
        while (try rt.next()) |runtime_value| {
            const v = try Value.fromRuntimeValue(result_allocator, runtime_value, query_target);
            try values.append(result_allocator, v);
        }
        const query_time = query_start.untilNow(self.io, .real);

        return .{
            .values = values,
            .stats = .{
                .parse_time = parse_time,
                .query_time = query_time,
            },
            .allocator = result_allocator,
        };
    }
};
