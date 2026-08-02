const std = @import("std");
const ts = @import("tree-sitter");
const ds = @import("../ds.zig");
const OverlayMap = ds.OverlayMap;
const Rc = ds.Rc;
const pcre2 = @import("../regex.zig");
const public = @import("../value.zig");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

pub const FieldId = ir.FieldId;
pub const Address = ir.Address;
pub const Symbol = ir.Symbol;
pub const VariableId = ir.VariableId;
pub const NodeKindId = ir.NodeKindId;

pub const Point = public.Point;
pub const Range = public.Range;

pub const Value = union(enum) {
    nothing,
    bool: bool,
    uint: u64,
    string: []const u8,
    range: Range,
    kind_id: NodeKindId,
    field_id: FieldId,
    node: ts.Node,
    // NOTE: Do we want to reference the value directly or via e.g. a regex
    // pool in the runtime? Mostly a question of ownership I guess
    regex: pcre2.Regex,
    record: *Rc(Record),
    list: *Rc(List),

    /// Bump refcounts on heap variants; no-op for inline ones. Producers
    /// (asn, push_build, yield) call this before handing a Value to a new
    /// owner.
    pub fn clone(self: Value) Value {
        return switch (self) {
            .record => |r| .{ .record = r.reference() },
            .list => |l| .{ .list = l.reference() },
            else => self,
        };
    }

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .record => |r| r.dereference(gpa),
            .list => |l| l.dereference(gpa),
            else => {},
        }
    }

    pub fn eql(a: Value, b: Value) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;

        return switch (a) {
            .nothing => true,
            .bool => |bv| bv == b.bool,
            .uint => |uint| uint == b.uint,
            .string => |a_str| std.mem.eql(u8, a_str, b.string),
            .range => |a_range| {
                const b_range = b.range;
                return a_range.start_byte == b_range.start_byte and
                    a_range.end_byte == b_range.end_byte and
                    a_range.start_point.row == b_range.start_point.row and
                    a_range.start_point.column == b_range.start_point.column and
                    a_range.end_point.row == b_range.end_point.row and
                    a_range.end_point.column == b_range.end_point.column;
            },
            .kind_id => |a_kind| a_kind == b.kind_id,
            .field_id => |a_field| a_field == b.field_id,
            .node => |a_node| a_node.eql(b.node),
            .regex => |a_regex| a_regex.eql(b.regex),
            .record => |a_r| a_r == b.record,
            .list => |a_l| a_l == b.list,
        };
    }

    pub fn print(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .nothing => try writer.print("nothing", .{}),
            .bool => |bv| try writer.print("bool {}", .{bv}),
            .uint => |uint| try writer.print("uint {}", .{uint}),
            .string => |s| try writer.print("string \"{s}\"", .{s}),
            .kind_id => |k| try writer.print("kind_id {}", .{k}),
            .field_id => |f| try writer.print("field_id {}", .{f}),
            .range => try writer.print("range ...", .{}),
            .node => try writer.print("node ...", .{}),
            .regex => try writer.print("regex ...", .{}),
            .record => try writer.print("record ...", .{}),
            .list => try writer.print("list ...", .{}),
        }
    }

    pub fn toPublic(self: Value, gpa: Allocator, source: []const u8) error{OutOfMemory}!public.Value {
        return switch (self) {
            .nothing => .nothing,
            .bool => |b| .{ .bool = b },
            .uint => |u| .{ .uint = u },
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            .range => |r| .{ .range = r },
            .node => |n| blk: {
                const sp = n.startPoint();
                const ep = n.endPoint();
                const kind = try gpa.dupe(u8, n.kind());
                errdefer gpa.free(kind);
                const text = try gpa.dupe(u8, source[n.startByte()..n.endByte()]);
                break :blk .{ .node = .{
                    .kind = kind,
                    .text = text,
                    .start_byte = n.startByte(),
                    .end_byte = n.endByte(),
                    .start_point = .{ .row = sp.row, .column = sp.column },
                    .end_point = .{ .row = ep.row, .column = ep.column },
                } };
            },
            .record => |rc| blk: {
                const entries = try gpa.alloc(public.RecordEntry, rc.value.map.count());
                errdefer gpa.free(entries);
                var it = rc.value.map.iterator();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) {
                    entries[i] = .{
                        .key = try gpa.dupe(u8, e.key_ptr.*),
                        .value = try e.value_ptr.*.toPublic(gpa, source),
                    };
                }
                std.mem.sort(public.RecordEntry, entries, {}, lessThanEntry);
                break :blk .{ .record = .{ ._entries = entries } };
            },
            .list => |rc| blk: {
                const items = try gpa.alloc(public.Value, rc.value.items.items.len);
                errdefer gpa.free(items);
                for (rc.value.items.items, 0..) |v, i| items[i] = try v.toPublic(gpa, source);
                break :blk .{ .list = .{ ._items = items } };
            },
            .kind_id, .field_id, .regex => @panic("TODO"),
        };
    }
};

fn lessThanEntry(_: void, a: public.RecordEntry, b: public.RecordEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

pub const Record = struct {
    map: std.StringHashMap(Value),

    pub fn init(gpa: Allocator) Record {
        return .{ .map = std.StringHashMap(Value).init(gpa) };
    }

    pub fn deinit(self: *Record, gpa: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        self.map.deinit();
    }
};

pub const List = struct {
    items: std.ArrayList(Value),

    pub fn init() List {
        return .{ .items = std.ArrayList(Value).empty };
    }

    pub fn deinit(self: *List, gpa: Allocator) void {
        for (self.items.items) |*v| v.deinit(gpa);
        self.items.deinit(gpa);
    }
};

// Use an OverlayMap to map variable ids to values. This is probably only more efficient than a
// standard hash map if we do more copies than lookups. But we probably do? May need to benchmark.
pub const Environment = OverlayMap(VariableId, Value);

/// A boundary is part of a stack frame. Its purpose is to embed otherwise
/// difficult-to-express control flow within the stack by modifying yield and
/// termination semantics.
pub const Boundary = union(enum) {
    // IMPROVE: maybe better named split? But it's _above_ a split...
    passthrough,
    /// Probe boundaries handle control flow of yield and branch termination.
    exists: struct {
        resume_address: ir.Address,
    },
    nexists: struct {
        resume_address: ir.Address,
    },
    aggregate: struct {
        resume_address: ir.Address,
        variable: ir.VariableId,
        value: union(ir.AggregatingValue) {
            list: *Rc(List),
            record: struct {
                rc: *Rc(Record),
                pending_key: ?[]const u8 = null,
            },
        },
    },
    call: struct {
        resume_address: ir.Address,
    },
    call_return: struct {
        call_boundary_idx: usize,
    },
};

pub const State = struct {
    pc: u32,
    value: Value,
    environment: Environment.Cell,
};

/// Frame represents a single execution context on the stack.
/// Each frame pairs an execution state with a boundary that defines
/// the frame's continuation semantics (how yield/termination behave).
pub const Frame = struct {
    state: State,
    boundary: Boundary,
    /// If present, this is a "virtual" frame that serves to generate frames
    /// from the split iterator. Once the iterator is exhausted, resume at
    /// resume_pc
    split: ?struct {
        iterator: SplitIterator,
        resume_pc: u32,
    } = null,
};

pub const Stack = std.ArrayList(Frame);

pub const RuntimeError = error{
    ExecuteOutOfBounds,
    InvalidArguments,
    StackCorruption,
    InvalidBuildConstruction,
    PanicInstruction,
    InvalidAST,
    UnexpectedType,
};

pub const ChildIterator = struct {
    cursor: ?ts.TreeCursor,
    started: bool,

    pub fn init(parent_node: ts.Node) ChildIterator {
        var cursor = parent_node.walk();
        if (!cursor.gotoFirstChild()) {
            cursor.destroy();
            return .{ .cursor = null, .started = false };
        }

        var iter = ChildIterator{
            .cursor = cursor,
            .started = false,
        };

        if (!cursor.node().isNamed()) {
            if (!iter.advance()) {
                cursor.destroy();
                return .{ .cursor = null, .started = false };
            }
        }

        return iter;
    }

    pub fn value(self: *const ChildIterator) Value {
        return .{ .node = self.cursor.?.node() };
    }

    pub fn next(self: *ChildIterator) bool {
        if (self.cursor == null) return false;
        if (!self.started) {
            self.started = true;
            return true;
        }
        return self.advance();
    }

    fn advance(self: *ChildIterator) bool {
        var cursor = &self.cursor.?;
        while (cursor.gotoNextSibling()) {
            if (cursor.node().isNamed()) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *ChildIterator) void {
        if (self.cursor) |*c| c.destroy();
    }
};

pub const FieldIterator = struct {
    cursor: ?ts.TreeCursor,
    field_id: FieldId,
    started: bool,

    pub fn init(parent_node: ts.Node, field_id: FieldId) FieldIterator {
        var cursor = parent_node.walk();
        if (!cursor.gotoFirstChild()) {
            cursor.destroy();
            return .{ .cursor = null, .field_id = field_id, .started = false };
        }

        var iter = FieldIterator{
            .cursor = cursor,
            .field_id = field_id,
            .started = false,
        };

        // If the first child doesn't match the field, advance to find one that does
        if (cursor.fieldId() != field_id) {
            if (!iter.advance()) {
                cursor.destroy();
                return .{ .cursor = null, .field_id = field_id, .started = false };
            }
        }

        return iter;
    }

    pub fn value(self: *const FieldIterator) Value {
        return .{ .node = self.cursor.?.node() };
    }

    pub fn next(self: *FieldIterator) bool {
        if (self.cursor == null) return false;
        if (!self.started) {
            self.started = true;
            return true;
        }
        return self.advance();
    }

    fn advance(self: *FieldIterator) bool {
        var cursor = &self.cursor.?;
        while (cursor.gotoNextSibling()) {
            if (cursor.fieldId() == self.field_id) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *FieldIterator) void {
        if (self.cursor) |*c| c.destroy();
    }
};

pub const DescendantIterator = struct {
    cursor: ?ts.TreeCursor,
    current_index: u32,
    descendant_count: u32,

    pub fn init(parent_node: ts.Node) DescendantIterator {
        const descendant_count = parent_node.descendantCount();
        if (descendant_count == 0) {
            return .{ .cursor = null, .current_index = 0, .descendant_count = 0 };
        }

        var cursor = parent_node.walk();

        var iter = DescendantIterator{
            .cursor = cursor,
            .current_index = 0,
            .descendant_count = descendant_count,
        };

        if (!cursor.node().isNamed()) {
            if (!iter.advance()) {
                cursor.destroy();
                return .{ .cursor = null, .current_index = 0, .descendant_count = 0 };
            }
        }

        return iter;
    }

    pub fn value(self: *const DescendantIterator) Value {
        return .{ .node = self.cursor.?.node() };
    }

    pub fn next(self: *DescendantIterator) bool {
        if (self.cursor == null) return false;
        return self.advance();
    }

    fn advance(self: *DescendantIterator) bool {
        var cursor = &self.cursor.?;
        while (self.current_index + 1 < self.descendant_count) {
            self.current_index += 1;
            cursor.gotoDescendant(self.current_index);

            if (cursor.node().isNamed()) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *DescendantIterator) void {
        if (self.cursor) |*c| c.destroy();
    }
};

pub const SingletonIterator = struct {
    pending: ?Value,
    current: Value = .nothing,

    pub fn init(maybe_value: ?Value) SingletonIterator {
        return .{ .pending = maybe_value };
    }

    pub fn value(self: *const SingletonIterator) Value {
        return self.current;
    }

    pub fn next(self: *SingletonIterator) bool {
        if (self.pending) |v| {
            self.current = v;
            self.pending = null;
            return true;
        }
        return false;
    }

    pub fn deinit(_: *SingletonIterator) void {}
};

pub const SplitIterator = union(enum) {
    child: ChildIterator,
    descendant: DescendantIterator,
    field: FieldIterator,
    singleton: SingletonIterator,

    pub fn value(self: *const SplitIterator) Value {
        return switch (self.*) {
            .child => |*iter| iter.value(),
            .descendant => |*iter| iter.value(),
            .field => |*iter| iter.value(),
            .singleton => |*iter| iter.value(),
        };
    }

    pub fn next(self: *SplitIterator) bool {
        return switch (self.*) {
            .child => |*iter| iter.next(),
            .descendant => |*iter| iter.next(),
            .field => |*iter| iter.next(),
            .singleton => |*iter| iter.next(),
        };
    }

    pub fn deinit(self: *SplitIterator) void {
        switch (self.*) {
            .child => |*iter| iter.deinit(),
            .descendant => |*iter| iter.deinit(),
            .field => |*iter| iter.deinit(),
            .singleton => |*iter| iter.deinit(),
        }
    }
};
