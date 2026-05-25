const std = @import("std");
const ts = @import("tree-sitter");
const ds = @import("../ds.zig");
const OverlayMap = ds.OverlayMap;
const Rc = ds.Rc;
const pcre2 = @import("../regex.zig");

const Allocator = std.mem.Allocator;

pub const FieldId = u16;
pub const Address = u32;
pub const Symbol = u32;
pub const VariableId = u32;
pub const NodeKindId = u16;

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

pub const Value = union(enum) {
    nothing,
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

    pub fn print(self: Value, writer: anytype) !void {
        switch (self) {
            .nothing => try writer.print("nothing", .{}),
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
};

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
/// difficult-to-express control flow within the stack.
pub const Boundary = union(enum) {
    root,
    // IMPROVE: maybe better named split? But it's _above_ a split...
    passthrough,
    probe: union(enum) {
        exists: Address,
        nexists: Address,
    },
    call,
};

pub const Vector = enum {
    record,
    list,
};

pub const State = struct {
    pc: u32,
    node: ts.Node,
    environment: Environment.Cell,
    negate_flag: bool = false,
    build: ?union(Vector) {
        record: *Rc(Record),
        list: *Rc(List),
    } = null,
};

/// Frame represents a single execution context on the stack.
/// Each frame pairs an execution state with a boundary that defines
/// the frame's continuation semantics (how yield/halt behave).
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

    pub fn node(self: *const ChildIterator) ts.Node {
        return self.cursor.?.node();
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

    pub fn node(self: *const FieldIterator) ts.Node {
        return self.cursor.?.node();
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

    pub fn node(self: *const DescendantIterator) ts.Node {
        return self.cursor.?.node();
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
    pending: ?ts.Node,
    current: ts.Node = undefined,

    pub fn init(maybe_node: ?ts.Node) SingletonIterator {
        return .{ .pending = maybe_node };
    }

    pub fn node(self: *const SingletonIterator) ts.Node {
        return self.current;
    }

    pub fn next(self: *SingletonIterator) bool {
        if (self.pending) |n| {
            self.current = n;
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

    pub fn node(self: *const SplitIterator) ts.Node {
        return switch (self.*) {
            .child => |*iter| iter.node(),
            .descendant => |*iter| iter.node(),
            .field => |*iter| iter.node(),
            .singleton => |*iter| iter.node(),
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

pub const Axis = union(enum) {
    child,
    descendant,
    // NOTE: Consider removing this since it's accomplishable with cmp on child
    // and likely not much more efficient
    field: FieldId,
    variable_id: VariableId,
};

pub const NodeValueSource = enum {
    const Self = @This();

    this,
    text,
    kind,
    range,
};

pub const ValueSource = union(enum) {
    literal: Value,
    node: NodeValueSource,
    variable_id: VariableId,

    pub fn print(self: ValueSource, writer: anytype) !void {
        switch (self) {
            .literal => |l| {
                try writer.print("literal ", .{});
                switch (l) {
                    .nothing => try writer.print("nothing", .{}),
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
            },
            .node => |n| try writer.print("node {s}", .{@tagName(n)}),
            .variable_id => |v| try writer.print("variable_id {}", .{v}),
        }
    }
};

pub const ProbeMode = enum {
    exists,
    nexists,
};

pub const Relation = enum {
    equals,
    like,
    lt,
    gt,
};

pub const Condition = enum {
    always,
    relates,
    not_relates,
};

pub const Instruction = union(enum) {
    noop,
    halt: struct { condition: Condition = .always },
    trv: Axis,
    asn: struct {
        variable_id: VariableId,
        source: ValueSource,
    },
    rel: struct {
        relation: Relation,
        a: ValueSource,
        b: ValueSource,
    },
    yield: struct {
        source: ValueSource = .{ .node = .this },
    },
    probe: struct {
        mode: ProbeMode,
        on_success: Address,
    },
    call: Address,
    ret,
    jmp: struct {
        address: Address,
        mode: Condition = .always,
    },
    begin_build: Vector,
    push_build: struct {
        source: ValueSource,
        // only applicable for records
        name: ?[]const u8,
    },
    end_build: VariableId,
    panic, // debug, probably remove

    pub fn print(self: Instruction, writer: anytype) !void {
        switch (self) {
            .noop => try writer.print("noop", .{}),
            .yield => try writer.print("yield", .{}),
            .halt => |h| try writer.print("halt {s}", .{@tagName(h.condition)}),
            .trv => |t| {
                try writer.print("trv ", .{});
                switch (t) {
                    .child => try writer.print("child", .{}),
                    .descendant => try writer.print("descendant", .{}),
                    .field => |f| try writer.print("field {}", .{f}),
                    .variable_id => |v| try writer.print("variable_id {}", .{v}),
                }
            },
            .asn => |a| {
                try writer.print("asn {} (", .{a.variable_id});
                try a.source.print(writer);
                try writer.print(")", .{});
            },
            .rel => |r| {
                try writer.print("rel {s} (", .{@tagName(r.relation)});
                try r.a.print(writer);
                try writer.print(") (", .{});
                try r.b.print(writer);
                try writer.print(")", .{});
            },
            .probe => |p| try writer.print("probe {s} {}", .{ @tagName(p.mode), p.on_success }),
            .call => |c| try writer.print("call {}", .{c}),
            .ret => try writer.print("ret", .{}),
            .jmp => |j| try writer.print("jmp {s} {}", .{ @tagName(j.mode), j.address }),
            .begin_build => |v| try writer.print("begin_build {s}", .{@tagName(v)}),
            .push_build => |i| {
                if (i.name) |name| {
                    try writer.print("push_build {s} (", .{name});
                } else {
                    try writer.print("push_build (", .{});
                }
                try i.source.print(writer);
                try writer.print(")", .{});
            },
            .end_build => |v| try writer.print("end_build {}", .{v}),
            .panic => try writer.print("panic", .{}),
        }
    }
};
