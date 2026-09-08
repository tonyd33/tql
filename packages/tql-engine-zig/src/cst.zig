const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Span = diagnostic.Span;
pub const Identifier = []const u8;

pub const SourceFile = struct {
    declarations: []const Declaration,
    span: Span = .unknown,

    pub fn deinit(self: SourceFile, allocator: std.mem.Allocator) void {
        for (self.declarations) |d| d.deinit(allocator);
        allocator.free(self.declarations);
    }

    pub fn sexpr(self: SourceFile, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(source_file");
        for (self.declarations) |d| {
            try w.writeByte(' ');
            try d.sexpr(w);
        }
        try w.writeByte(')');
    }

    pub fn sexprAlloc(self: SourceFile, allocator: std.mem.Allocator) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(allocator);
        errdefer w.deinit();
        try self.sexpr(&w.writer);
        return try w.toOwnedSlice();
    }
};

/// `name : type;` or `name p1 p2 = body;`.
///
/// `main` is not distinguished here. Rejecting `main x = x` is a whole-program
/// property, and the span its fixture pins is this node's.
pub const Declaration = union(enum) {
    signature: Signature,
    definition: Definition,

    pub fn span(self: Declaration) Span {
        return switch (self) {
            inline else => |d| d.span,
        };
    }

    pub fn deinit(self: Declaration, allocator: std.mem.Allocator) void {
        switch (self) {
            inline else => |d| d.deinit(allocator),
        }
    }

    pub fn sexpr(self: Declaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |d| try d.sexpr(w),
        }
    }
};

pub const Signature = struct {
    name: Identifier,
    type: Type,
    span: Span = .unknown,

    pub fn deinit(self: Signature, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.type.deinit(allocator);
    }

    pub fn sexpr(self: Signature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(signature {s} ", .{self.name});
        try self.type.sexpr(w);
        try w.writeByte(')');
    }
};

pub const Definition = struct {
    name: Identifier,
    parameters: []const Parameter,
    body: Expression,
    span: Span = .unknown,

    pub fn deinit(self: Definition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.parameters) |p| p.deinit(allocator);
        allocator.free(self.parameters);
        self.body.deinit(allocator);
    }

    pub fn sexpr(self: Definition, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(define {s} (params", .{self.name});
        for (self.parameters) |p| {
            try w.writeByte(' ');
            try w.writeAll(p.name);
        }
        try w.writeAll(") ");
        try self.body.sexpr(w);
        try w.writeByte(')');
    }
};

pub const Parameter = struct {
    name: Identifier,
    span: Span = .unknown,

    pub fn deinit(self: Parameter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// A `let` binding, which is a definition without the terminator: `f x = e`.
pub const Binding = struct {
    name: Identifier,
    parameters: []const Parameter,
    value: Expression,
    span: Span = .unknown,

    pub fn deinit(self: Binding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.parameters) |p| p.deinit(allocator);
        allocator.free(self.parameters);
        self.value.deinit(allocator);
    }

    pub fn sexpr(self: Binding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(bind {s} (params", .{self.name});
        for (self.parameters) |p| {
            try w.writeByte(' ');
            try w.writeAll(p.name);
        }
        try w.writeAll(") ");
        try self.value.sexpr(w);
        try w.writeByte(')');
    }
};

pub const BinaryOperator = enum {
    divide,
    multiply,
    modulo,
    add,
    subtract,
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    match,
    not_match,
    @"and",
    @"or",
    pipe,
    stream_union,

    pub fn spelling(self: BinaryOperator) []const u8 {
        return switch (self) {
            .divide => "/",
            .multiply => "*",
            .modulo => "%",
            .add => "+",
            .subtract => "-",
            .eq => "=",
            .ne => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .match => "~",
            .not_match => "!~",
            .@"and" => "and",
            .@"or" => "or",
            .pipe => "|",
            .stream_union => ",",
        };
    }
};

pub const Binary = struct {
    operator: BinaryOperator,
    left: Expression,
    right: Expression,
};

pub const Apply = struct {
    function: Expression,
    argument: Expression,
};

pub const FieldAccess = struct {
    /// Absent for a leading `.field`, whose record is the implicit input.
    record: ?Expression,
    field: Identifier,
};

pub const Not = struct {
    operand: Expression,
};

pub const If = struct {
    condition: Expression,
    consequence: Expression,
    alternative: Expression,
};

pub const Lambda = struct {
    parameters: []const Parameter,
    body: Expression,
};

pub const Let = struct {
    bindings: []const Binding,
    body: Expression,
};

pub const Do = struct {
    statements: []const Statement,
    result: Expression,
};

/// A `do`-block statement. The final expression is the block's `result` and is
/// not a statement.
pub const Statement = union(enum) {
    bind: BindStatement,
    let: LetStatement,

    pub fn deinit(self: Statement, allocator: std.mem.Allocator) void {
        switch (self) {
            .bind => |b| {
                allocator.free(b.name);
                b.value.deinit(allocator);
            },
            .let => |l| {
                for (l.bindings) |b| b.deinit(allocator);
                allocator.free(l.bindings);
            },
        }
    }

    pub fn sexpr(self: Statement, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .bind => |b| {
                try w.print("(<- {s} ", .{b.name});
                try b.value.sexpr(w);
                try w.writeByte(')');
            },
            .let => |l| {
                try w.writeAll("(let");
                for (l.bindings) |b| {
                    try w.writeByte(' ');
                    try b.sexpr(w);
                }
                try w.writeByte(')');
            },
        }
    }
};

pub const BindStatement = struct {
    name: Identifier,
    value: Expression,
    span: Span = .unknown,
};

pub const LetStatement = struct {
    bindings: []const Binding,
    span: Span = .unknown,
};

pub const RecordField = struct {
    name: Identifier,
    value: Expression,
    span: Span = .unknown,

    pub fn deinit(self: RecordField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
    }
};

pub const Record = struct {
    fields: []const RecordField,
};

pub const Expression = struct {
    kind: Kind,
    span: Span = .unknown,

    pub const Kind = union(enum) {
        identity,
        /// `:class_declaration`, carried without the leading colon.
        kind_test: Identifier,
        name: Identifier,
        number: i64,
        string: []const u8,
        boolean: bool,
        regex: []const u8,
        field_access: *FieldAccess,
        apply: *Apply,
        binary: *Binary,
        not: *Not,
        @"if": *If,
        lambda: *Lambda,
        let: *Let,
        do: *Do,
        /// A collected stream: `[e]` or `[]`.
        list: ?*Expression,
        record: Record,
        parenthesized: *Expression,
    };

    pub fn deinit(self: Expression, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .identity, .number, .boolean => {},
            .kind_test => |k| allocator.free(k),
            .name => |n| allocator.free(n),
            .string => |s| allocator.free(s),
            .regex => |r| allocator.free(r),
            .field_access => |fa| {
                if (fa.record) |r| r.deinit(allocator);
                allocator.free(fa.field);
                allocator.destroy(fa);
            },
            .apply => |a| {
                a.function.deinit(allocator);
                a.argument.deinit(allocator);
                allocator.destroy(a);
            },
            .binary => |b| {
                b.left.deinit(allocator);
                b.right.deinit(allocator);
                allocator.destroy(b);
            },
            .not => |n| {
                n.operand.deinit(allocator);
                allocator.destroy(n);
            },
            .@"if" => |i| {
                i.condition.deinit(allocator);
                i.consequence.deinit(allocator);
                i.alternative.deinit(allocator);
                allocator.destroy(i);
            },
            .lambda => |l| {
                for (l.parameters) |p| p.deinit(allocator);
                allocator.free(l.parameters);
                l.body.deinit(allocator);
                allocator.destroy(l);
            },
            .let => |l| {
                for (l.bindings) |b| b.deinit(allocator);
                allocator.free(l.bindings);
                l.body.deinit(allocator);
                allocator.destroy(l);
            },
            .do => |d| {
                for (d.statements) |s| s.deinit(allocator);
                allocator.free(d.statements);
                d.result.deinit(allocator);
                allocator.destroy(d);
            },
            .list => |maybe| {
                if (maybe) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
            },
            .record => |r| {
                for (r.fields) |f| f.deinit(allocator);
                allocator.free(r.fields);
            },
            .parenthesized => |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            },
        }
    }

    pub fn sexpr(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .identity => try w.writeAll("."),
            .kind_test => |k| try w.print("(kind {s})", .{k}),
            .name => |n| try w.print("{s}", .{n}),
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("(string \"{s}\")", .{s}),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .regex => |r| try w.print("(regex \"{s}\")", .{r}),
            .field_access => |fa| {
                try w.writeAll("(field ");
                if (fa.record) |r| {
                    try r.sexpr(w);
                } else {
                    try w.writeAll(".");
                }
                try w.print(" {s})", .{fa.field});
            },
            .apply => |a| {
                try w.writeAll("(apply ");
                try a.function.sexpr(w);
                try w.writeByte(' ');
                try a.argument.sexpr(w);
                try w.writeByte(')');
            },
            .binary => |b| {
                try w.print("({s} ", .{b.operator.spelling()});
                try b.left.sexpr(w);
                try w.writeByte(' ');
                try b.right.sexpr(w);
                try w.writeByte(')');
            },
            .not => |n| {
                try w.writeAll("(not ");
                try n.operand.sexpr(w);
                try w.writeByte(')');
            },
            .@"if" => |i| {
                try w.writeAll("(if ");
                try i.condition.sexpr(w);
                try w.writeByte(' ');
                try i.consequence.sexpr(w);
                try w.writeByte(' ');
                try i.alternative.sexpr(w);
                try w.writeByte(')');
            },
            .lambda => |l| {
                try w.writeAll("(lambda (params");
                for (l.parameters) |p| {
                    try w.writeByte(' ');
                    try w.writeAll(p.name);
                }
                try w.writeAll(") ");
                try l.body.sexpr(w);
                try w.writeByte(')');
            },
            .let => |l| {
                try w.writeAll("(let (");
                for (l.bindings, 0..) |b, i| {
                    if (i > 0) try w.writeByte(' ');
                    try b.sexpr(w);
                }
                try w.writeAll(") ");
                try l.body.sexpr(w);
                try w.writeByte(')');
            },
            .do => |d| {
                try w.writeAll("(do");
                for (d.statements) |s| {
                    try w.writeByte(' ');
                    try s.sexpr(w);
                }
                try w.writeByte(' ');
                try d.result.sexpr(w);
                try w.writeByte(')');
            },
            .list => |maybe| {
                try w.writeAll("(list");
                if (maybe) |e| {
                    try w.writeByte(' ');
                    try e.sexpr(w);
                }
                try w.writeByte(')');
            },
            .record => |r| {
                try w.writeAll("(record");
                for (r.fields) |f| {
                    try w.print(" ({s} ", .{f.name});
                    try f.value.sexpr(w);
                    try w.writeByte(')');
                }
                try w.writeByte(')');
            },
            .parenthesized => |e| {
                try w.writeAll("(paren ");
                try e.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

// ============================================================================
// Types
// ============================================================================

pub const FunctionType = struct {
    from: Type,
    to: Type,
};

pub const FilterType = struct {
    input: Type,
    output: Type,
};

pub const TypeField = struct {
    name: Identifier,
    type: Type,
    span: Span = .unknown,

    pub fn deinit(self: TypeField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.type.deinit(allocator);
    }
};

pub const Type = struct {
    kind: Kind,
    span: Span = .unknown,

    pub const Kind = union(enum) {
        /// A concrete type name: `Filter`'s operands aside, anything
        /// capitalized.
        constructor: Identifier,
        variable: Identifier,
        function: *FunctionType,
        filter: *FilterType,
        list: *Type,
        record: []const TypeField,
        parenthesized: *Type,
    };

    pub fn deinit(self: Type, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .constructor => |c| allocator.free(c),
            .variable => |v| allocator.free(v),
            .function => |f| {
                f.from.deinit(allocator);
                f.to.deinit(allocator);
                allocator.destroy(f);
            },
            .filter => |f| {
                f.input.deinit(allocator);
                f.output.deinit(allocator);
                allocator.destroy(f);
            },
            .list => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
            .record => |fields| {
                for (fields) |f| f.deinit(allocator);
                allocator.free(fields);
            },
            .parenthesized => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
        }
    }

    pub fn sexpr(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .constructor => |c| try w.print("{s}", .{c}),
            .variable => |v| try w.print("{s}", .{v}),
            .function => |f| {
                try w.writeAll("(-> ");
                try f.from.sexpr(w);
                try w.writeByte(' ');
                try f.to.sexpr(w);
                try w.writeByte(')');
            },
            .filter => |f| {
                try w.writeAll("(Filter ");
                try f.input.sexpr(w);
                try w.writeByte(' ');
                try f.output.sexpr(w);
                try w.writeByte(')');
            },
            .list => |t| {
                try w.writeAll("(list_type ");
                try t.sexpr(w);
                try w.writeByte(')');
            },
            .record => |fields| {
                try w.writeAll("(record_type");
                for (fields) |f| {
                    try w.print(" ({s} ", .{f.name});
                    try f.type.sexpr(w);
                    try w.writeByte(')');
                }
                try w.writeByte(')');
            },
            .parenthesized => |t| {
                try w.writeAll("(paren_type ");
                try t.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};
