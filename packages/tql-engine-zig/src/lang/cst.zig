const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const string_literal = @import("string_literal.zig");

pub const Identifier = []const u8;

pub const SourceFile = struct {
    declarations: []const Declaration,
    span: diagnostic.Span = .unknown,

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
pub const Declaration = union(enum) {
    signature: Signature,
    definition: Definition,
    type_declaration: TypeDeclaration,

    pub fn span(self: Declaration) diagnostic.Span {
        return switch (self) {
            inline else => |d| d.span,
        };
    }

    pub fn sexpr(self: Declaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |d| try d.sexpr(w),
        }
    }
};

/// `name : context => type;`, where the context may be absent.
pub const Signature = struct {
    name: Identifier,
    context: []const ClassConstraint = &.{},
    type: Type,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: Signature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(signature {s} ", .{self.name});
        if (self.context.len > 0) {
            try w.writeAll("(=>");
            for (self.context) |c| try w.print(" ({s} {s})", .{ c.class, c.variable });
            try w.writeAll(") ");
        }
        try self.type.sexpr(w);
        try w.writeByte(')');
    }
};

/// `Sized a` in a signature's context.
pub const ClassConstraint = struct {
    class: Identifier,
    variable: Identifier,
    span: diagnostic.Span = .unknown,
};

pub const Definition = struct {
    name: Identifier,
    parameters: []const Parameter,
    body: Expression,
    span: diagnostic.Span = .unknown,

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

/// `type T a = C1 f1 f2 | C2;`
pub const TypeDeclaration = struct {
    name: Identifier,
    parameters: []const Identifier,
    constructors: []const ConstructorDeclaration,
    deriving: ?Deriving = null,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: TypeDeclaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(type {s} (params", .{self.name});
        for (self.parameters) |p| try w.print(" {s}", .{p});
        try w.writeAll(")");
        for (self.constructors) |c| {
            try w.writeByte(' ');
            try c.sexpr(w);
        }
        if (self.deriving) |d| {
            try w.writeAll(" (deriving");
            for (d.classes) |c| try w.print(" {s}", .{c.name});
            try w.writeByte(')');
        }
        try w.writeByte(')');
    }
};

/// `deriving (Eq, Ord)` on a type declaration.
pub const Deriving = struct {
    classes: []const DerivedClass,
    span: diagnostic.Span = .unknown,
};

pub const DerivedClass = struct {
    name: Identifier,
    span: diagnostic.Span = .unknown,
};

pub const ConstructorDeclaration = struct {
    name: Identifier,
    fields: []const Type,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: ConstructorDeclaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(con {s}", .{self.name});
        for (self.fields) |f| {
            try w.writeByte(' ');
            try f.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const Parameter = struct {
    name: Identifier,
    span: diagnostic.Span = .unknown,
};

/// A `let` binding, which is a definition without the terminator: `f x = e`.
pub const Binding = struct {
    name: Identifier,
    parameters: []const Parameter,
    value: Expression,
    span: diagnostic.Span = .unknown,

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
            .stream_union => "<|>",
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
    expression: Expression,

    pub fn sexpr(self: Statement, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .bind => |b| {
                try w.print("(<- {s} ", .{b.name});
                try b.value.sexpr(w);
                try w.writeByte(')');
            },
            .expression => |e| {
                try w.writeAll("(>> ");
                try e.sexpr(w);
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
    span: diagnostic.Span = .unknown,
};

pub const LetStatement = struct {
    bindings: []const Binding,
    span: diagnostic.Span = .unknown,
};

pub const RecordField = struct {
    name: Identifier,
    value: Expression,
    span: diagnostic.Span = .unknown,
};

pub const Record = struct {
    fields: []const RecordField,
};

pub const Expression = struct {
    kind: Kind,
    span: diagnostic.Span = .unknown,

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
        @"if": *If,
        case: *Case,
        /// A data constructor used as a value: `Nil`, `True`.
        constructor: Identifier,
        lambda: *Lambda,
        let: *Let,
        do: *Do,
        /// A list literal: `[a, b, c]` or `[]`.
        list: []const Expression,
        record: Record,
        parenthesized: *Expression,
    };

    pub fn sexpr(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .identity => try w.writeAll("."),
            .kind_test => |k| try w.print("(kind {s})", .{k}),
            .name => |n| try w.print("{s}", .{n}),
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("(string \"{f}\")", .{string_literal.fmt(s)}),
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
            .case => |c| {
                try w.writeAll("(case ");
                try c.scrutinee.sexpr(w);
                for (c.alternatives) |a| {
                    try w.writeAll(" (alt ");
                    try a.pattern.sexpr(w);
                    try w.writeByte(' ');
                    try a.body.sexpr(w);
                    try w.writeByte(')');
                }
                try w.writeByte(')');
            },
            .constructor => |c| try w.print("{s}", .{c}),
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
            .list => |elements| {
                try w.writeAll("(list");
                for (elements) |e| {
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

pub const TypeApplication = struct {
    constructor: Identifier,
    arguments: []const Type,
};

pub const TypeField = struct {
    name: Identifier,
    type: Type,
    span: diagnostic.Span = .unknown,
};

/// `case e of { p -> e; ... }`
pub const Case = struct {
    scrutinee: Expression,
    alternatives: []const Alternative,

    pub const Alternative = struct {
        pattern: Pattern,
        body: Expression,
        span: diagnostic.Span = .unknown,
    };
};

/// The left side of a `case` alternative.
pub const Pattern = struct {
    kind: Kind,
    span: diagnostic.Span = .unknown,

    pub const Kind = union(enum) {
        /// `x` binds the matched value. `_` binds nothing.
        variable: Identifier,
        constructor: Constructor,
    };

    pub const Constructor = struct {
        name: Identifier,
        arguments: []const Pattern,
    };

    pub fn sexpr(self: Pattern, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .variable => |name| try w.writeAll(name),
            .constructor => |c| {
                if (c.arguments.len == 0) return w.writeAll(c.name);
                try w.print("({s}", .{c.name});
                for (c.arguments) |argument| {
                    try w.writeByte(' ');
                    try argument.sexpr(w);
                }
                try w.writeByte(')');
            },
        }
    }
};

pub const Type = struct {
    kind: Kind,
    span: diagnostic.Span = .unknown,

    pub const Kind = union(enum) {
        /// A concrete type name: `Filter`'s operands aside, anything
        /// capitalized.
        constructor: Identifier,
        /// A declared type at its arguments, like `List a`.
        application: *TypeApplication,
        variable: Identifier,
        function: *FunctionType,
        filter: *FilterType,
        list: *Type,
        record: []const TypeField,
        parenthesized: *Type,
    };

    pub fn sexpr(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .constructor => |c| try w.print("{s}", .{c}),
            .application => |a| {
                try w.print("({s}", .{a.constructor});
                for (a.arguments) |arg| {
                    try w.writeByte(' ');
                    try arg.sexpr(w);
                }
                try w.writeByte(')');
            },
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
