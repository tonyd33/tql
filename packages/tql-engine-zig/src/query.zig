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

    pub fn fromTsNode(ts_node: ts.Node, source: []const u8) Node {
        const start_point = ts_node.startPoint();
        const end_point = ts_node.endPoint();
        return Node{
            .kind = ts_node.kind(),
            .text = source[ts_node.startByte()..ts_node.endByte()],
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
};

pub const Value = union(enum) {
    nothing: void,
    string: []const u8,
    node: Node,
    range: runtime.Range,
    record: Record,
    list: List,

    pub fn fromRuntimeValue(gpa: Allocator, val: runtime.Value, source: []const u8) error{OutOfMemory}!Value {
        return switch (val) {
            .nothing => .{ .nothing = {} },
            .string => |s| .{ .string = s },
            .node => |n| .{ .node = Node.fromTsNode(n, source) },
            .range => |r| .{ .range = r },
            .record => |rc| .{ .record = try Record.fromRuntime(gpa, &rc.value, source) },
            .list => |rc| .{ .list = try List.fromRuntime(gpa, &rc.value, source) },
            else => .{ .nothing = {} },
        };
    }

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .record => |*r| r.deinit(gpa),
            .list => |*l| l.deinit(gpa),
            else => {},
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
                .key = e.key_ptr.*,
                .value = try Value.fromRuntimeValue(gpa, e.value_ptr.*, source),
            };
        }
        std.mem.sort(RecordEntry, entries, {}, lessThanEntry);
        return .{ .entries = entries };
    }

    pub fn deinit(self: *Record, gpa: Allocator) void {
        for (self.entries) |*e| e.value.deinit(gpa);
        gpa.free(self.entries);
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

    /// Borrow ProgramImage.
    pub fn init(program_image: *ProgramImage, language: Language) Query {
        return .{ .program_image = program_image, .language = language };
    }

    pub fn run(self: *Query, gpa: std.mem.Allocator, source_code: []const u8) !QueryResult {
        var stats = QueryStats{};

        var parse_timer = try std.time.Timer.start();
        const source_parser = ts.Parser.create();
        defer source_parser.destroy();

        try source_parser.setLanguage(self.language.getTreeSitterLanguage());
        const source_tree = source_parser.parseString(source_code, null) orelse return error.SourceParseFailed;
        defer source_tree.destroy();
        stats.parse_time_us = parse_timer.read() / 1000;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();

        var execute_timer = try std.time.Timer.start();
        var rt = runtime.Runtime.init(.{
            .tree = source_tree,
            .source = source_code,
            .instructions = self.program_image.instructions,
            .regexes = self.program_image.regexes,
            .allocator = allocator,
        });
        // FIXME: Regex assignments will fail. The regexes need to be owned by QueryResult
        defer rt.deinit();

        try rt.exec();

        var values_list = std.ArrayList(Value){};
        defer values_list.deinit(allocator);

        while (try rt.nextMatch()) |runtime_value| {
            // NOTE: If we're able to defer this to the consumer, we can save
            // a ton of heap allocations
            const enriched_value = try Value.fromRuntimeValue(gpa, runtime_value, source_code);
            try values_list.append(gpa, enriched_value);
        }

        const values = try values_list.toOwnedSlice(gpa);
        stats.execute_time_us = execute_timer.read() / 1000;

        return QueryResult{
            .values = values,
            .stats = stats,
            .allocator = gpa,
        };
    }

    pub fn deinit(_: *Query) void {}
};
