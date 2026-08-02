const std = @import("std");
const Allocator = std.mem.Allocator;
const pcre2 = @import("regex.zig");

pub const FieldId = u16;
pub const Address = u32;
pub const Symbol = u32;
pub const VariableId = u32;
pub const NodeKindId = u16;

pub const AggregatingValue = enum { list, record };

pub const AggregationSpec = struct {
    variable: VariableId,
    kind: AggregatingValue,
};

pub const Literal = union(enum) {
    nothing,
    bool: bool,
    uint: u64,
    string: []const u8,
    kind_id: NodeKindId,
    field_id: FieldId,
    // TODO: should this really be a literal?
    regex: pcre2.Regex,

    pub fn print(self: Literal, writer: *std.Io.Writer) !void {
        switch (self) {
            .nothing => try writer.print("nothing", .{}),
            .bool => |bv| try writer.print("bool {}", .{bv}),
            .uint => |uint| try writer.print("uint {}", .{uint}),
            .string => |s| try writer.print("string \"{s}\"", .{s}),
            .kind_id => |k| try writer.print("kind_id {}", .{k}),
            .field_id => |f| try writer.print("field_id {}", .{f}),
            .regex => try writer.print("regex ...", .{}),
        }
    }
};

pub const CurrentValueSource = enum {
    value,
    text,
    kind,
    range,
};

pub const ValueSource = union(enum) {
    literal: Literal,
    current: CurrentValueSource,
    variable_id: VariableId,

    pub fn print(self: ValueSource, writer: *std.Io.Writer) !void {
        switch (self) {
            .literal => |l| {
                try writer.print("literal ", .{});
                try l.print(writer);
            },
            .current => |c| try writer.print("(current value) {s}", .{@tagName(c)}),
            .variable_id => |v| try writer.print("variable_id {}", .{v}),
        }
    }
};

pub const Axis = union(enum) {
    child,
    descendant,
    // NOTE: Consider removing this since it's accomplishable with cmp on child
    // and likely not much more efficient
    field: FieldId,
    value_source: ValueSource,
};

pub const ProbeData = union(enum) {
    exists,
    nexists,
    aggregate: AggregationSpec,
};

pub const Relation = enum {
    equals,
    like,
    lt,
    gt,
};

pub const Instruction = union(enum) {
    noop,
    halt,
    trv: Axis,
    asn: struct {
        variable_id: VariableId,
        source: ValueSource,
    },
    rel: struct {
        relation: Relation,
        a: ValueSource,
        b: ValueSource,
        /// If set, write the bool result into this variable; else write into state.value.
        dest: ?VariableId = null,
    },
    yield: struct {
        source: ValueSource = .{ .current = .value },
    },
    // TODO: consolidate probe and call into single trap instruction
    probe: struct {
        resume_address: Address,
        data: ProbeData,
    },
    call: Address,
    jmp: struct {
        address: Address,
        /// When set, jump is conditional: taken iff source resolves to Value.bool == !negate.
        source: ?ValueSource = null,
        negate: bool = false,
    },
    panic, // debug, probably remove

    pub fn print(self: Instruction, writer: *std.Io.Writer) !void {
        switch (self) {
            .noop => try writer.print("noop", .{}),
            .yield => try writer.print("yield", .{}),
            .halt => try writer.print("halt", .{}),
            .trv => |t| {
                try writer.print("trv ", .{});
                switch (t) {
                    .child => try writer.print("child", .{}),
                    .descendant => try writer.print("descendant", .{}),
                    .field => |f| try writer.print("field {}", .{f}),
                    .value_source => |vs| {
                        try writer.print("value_source (", .{});
                        try vs.print(writer);
                        try writer.print(")", .{});
                    },
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
                if (r.dest) |d| {
                    try writer.print(") -> {}", .{d});
                } else {
                    try writer.print(")", .{});
                }
            },
            .probe => |p| switch (p.data) {
                .exists => try writer.print("probe exists {}", .{p.resume_address}),
                .nexists => try writer.print("probe nexists {}", .{p.resume_address}),
                .aggregate => |a| try writer.print("probe aggregate {} {} {s}", .{ p.resume_address, a.variable, @tagName(a.kind) }),
            },
            .call => |c| try writer.print("call {}", .{c}),
            .jmp => |j| if (j.source) |vs| {
                try writer.print("jmp {} if{s} (", .{ j.address, if (j.negate) " not" else "" });
                try vs.print(writer);
                try writer.print(")", .{});
            } else {
                try writer.print("jmp {}", .{j.address});
            },
            .panic => try writer.print("panic", .{}),
        }
    }
};

pub const ProgramImage = struct {
    instructions: []const Instruction,
    regexes: []pcre2.Regex,
    strings: []const []const u8,
    // IMPROVE: array of entry (variable id, string index)
    variable_map: std.hash_map.AutoHashMap(VariableId, []const u8),
    allocator: Allocator,

    pub fn deinit(self: *ProgramImage) void {
        self.variable_map.deinit();
        self.allocator.free(self.instructions);
        for (self.regexes) |*regex| regex.deinit();
        self.allocator.free(self.regexes);
        for (self.strings) |str| self.allocator.free(str);
        self.allocator.free(self.strings);
    }
};
