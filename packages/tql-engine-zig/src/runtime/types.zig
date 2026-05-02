const std = @import("std");
const ts = @import("tree-sitter");
const OverlayMap = @import("../overlay_map.zig").OverlayMap;
const pcre2 = @import("../pcre2.zig");

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
    // NOTE: If we ever need non-stack-allocatable values, prefer to defer
    // ownership and reference the value by pointer here, otherwise managing
    // the lifetime of values in the environment will be a nightmare!
    const Self = @This();

    nothing,
    string: []const u8,
    range: Range,
    kind_id: NodeKindId,
    field_id: FieldId,
    node: ts.Node,
    // NOTE: Do we want to reference the value directly or via e.g. a regex
    // pool in the runtime? Mostly a question of ownership I guess
    regex: pcre2.Regex,

    pub fn eql(a: Value, b: Value) bool {
        // Values must have the same tag to be equal
        if (@intFromEnum(a) != @intFromEnum(b)) {
            return false;
        }

        return switch (a) {
            .nothing => |a_nothing| a_nothing == b.nothing,
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
        };
    }
};

// Use an OverlayMap to map variable ids to values. This is probably only more efficient than a
// standard hash map if we do more copies than lookups. But we probably do? May need to benchmark.
pub const Environment = OverlayMap(VariableId, Value);

/// A boundary is part of a stack frame. Its purpose is to embed otherwise
/// difficult-to-express control flow within the stack.
pub const Boundary = union(enum) {
    root,
    passthrough,
    probe: union(enum) {
        exists: Address,
        nexists: Address,
    },
    call,
};

pub const State = struct {
    pc: u32,
    node: ts.Node,
    environment: *Environment,
    flag: bool = false,
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

pub const Match = struct {
    node: ts.Node,
    environment: *const Environment,
};

pub const RuntimeError = error{
    ExecuteOutOfBounds,
};

pub const ChildIterator = struct {
    cursor: ts.TreeCursor,
    started: bool,

    pub fn init(parent_node: ts.Node) ?ChildIterator {
        var cursor = parent_node.walk();
        const has_children = cursor.gotoFirstChild();
        if (!has_children) {
            cursor.destroy();
            return null;
        }

        var iter = ChildIterator{
            .cursor = cursor,
            .started = false,
        };

        if (!cursor.node().isNamed()) {
            if (!iter.advance()) {
                cursor.destroy();
                return null;
            }
        }

        return iter;
    }

    pub fn node(self: *const ChildIterator) ts.Node {
        return self.cursor.node();
    }

    pub fn next(self: *ChildIterator) bool {
        if (!self.started) {
            self.started = true;
            return true;
        }
        return self.advance();
    }

    fn advance(self: *ChildIterator) bool {
        while (self.cursor.gotoNextSibling()) {
            if (self.cursor.node().isNamed()) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *ChildIterator) void {
        self.cursor.destroy();
    }
};

pub const FieldIterator = struct {
    cursor: ts.TreeCursor,
    field_id: FieldId,
    started: bool,

    pub fn init(parent_node: ts.Node, field_id: FieldId) ?FieldIterator {
        var cursor = parent_node.walk();
        const has_children = cursor.gotoFirstChild();
        if (!has_children) {
            cursor.destroy();
            return null;
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
                return null;
            }
        }

        return iter;
    }

    pub fn node(self: *const FieldIterator) ts.Node {
        return self.cursor.node();
    }

    pub fn next(self: *FieldIterator) bool {
        if (!self.started) {
            self.started = true;
            return true;
        }
        return self.advance();
    }

    fn advance(self: *FieldIterator) bool {
        while (self.cursor.gotoNextSibling()) {
            if (self.cursor.fieldId() == self.field_id) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *FieldIterator) void {
        self.cursor.destroy();
    }
};

pub const DescendantIterator = struct {
    cursor: ts.TreeCursor,
    current_index: u32,
    descendant_count: u32,

    pub fn init(parent_node: ts.Node) ?DescendantIterator {
        const descendant_count = parent_node.descendantCount();
        if (descendant_count == 0) {
            return null;
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
                return null;
            }
        }

        return iter;
    }

    pub fn node(self: *const DescendantIterator) ts.Node {
        return self.cursor.node();
    }

    pub fn next(self: *DescendantIterator) bool {
        return self.advance();
    }

    fn advance(self: *DescendantIterator) bool {
        while (self.current_index + 1 < self.descendant_count) {
            self.current_index += 1;
            self.cursor.gotoDescendant(self.current_index);

            if (self.cursor.node().isNamed()) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *DescendantIterator) void {
        self.cursor.destroy();
    }
};

pub const SplitIterator = union(enum) {
    child: ChildIterator,
    descendant: DescendantIterator,
    field: FieldIterator,

    pub fn node(self: *const SplitIterator) ts.Node {
        return switch (self.*) {
            .child => |*iter| iter.node(),
            .descendant => |*iter| iter.node(),
            .field => |*iter| iter.node(),
        };
    }

    pub fn next(self: *SplitIterator) bool {
        return switch (self.*) {
            .child => |*iter| iter.next(),
            .descendant => |*iter| iter.next(),
            .field => |*iter| iter.next(),
        };
    }

    pub fn deinit(self: *SplitIterator) void {
        switch (self.*) {
            .child => |*iter| iter.deinit(),
            .descendant => |*iter| iter.deinit(),
            .field => |*iter| iter.deinit(),
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
    yield,
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
    panic, // debug, probably remove
};
