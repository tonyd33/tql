const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const string_literal = @import("string_literal.zig");

/// A name as written. A qualified name keeps its qualifier: `A.B.x` is
/// `x` from the import qualified as `A.B`.
pub const Identifier = []const u8;

pub const SourceFile = struct {
    header: ?ModuleHeader = null,
    imports: []const Import = &.{},
    declarations: []const Declaration,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: SourceFile, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(source_file");
        if (self.header) |h| {
            try w.print(" (module {s}", .{h.name});
            try sexprFilter(w, "exports", h.exports);
            if (h.grammars) |grammars| {
                try w.writeAll(" (for");
                for (grammars) |g| try w.print(" {s}", .{g});
                try w.writeByte(')');
            }
            try w.writeByte(')');
        }
        for (self.imports) |i| {
            try w.print(" (import {s}", .{i.module});
            try sexprFilter(w, "items", i.selects);
            if (i.qualifier) |q| try w.print(" (as {s})", .{q});
            try w.writeByte(')');
        }
        for (self.declarations) |d| {
            try w.writeByte(' ');
            try d.sexpr(w);
        }
        try w.writeByte(')');
    }

    fn sexprFilter(w: *std.Io.Writer, label: []const u8, filter: Filter) std.Io.Writer.Error!void {
        const items = switch (filter) {
            .all => return,
            .only => |items| items,
            .hiding => |items| items,
        };
        try w.print(" ({s}", .{if (filter == .hiding) "hiding" else label});
        for (items) |item| switch (item.kind) {
            .synonym => try w.print(" (pattern {s})", .{item.name}),
            .type_and_constructors => try w.print(" {s}(..)", .{item.name}),
            .value, .type => try w.print(" {s}", .{item.name}),
        };
        try w.writeByte(')');
    }

    pub fn sexprAlloc(self: SourceFile, allocator: std.mem.Allocator) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(allocator);
        errdefer w.deinit();
        try self.sexpr(&w.writer);
        return try w.toOwnedSlice();
    }
};

/// `module A.B (x, T(..));`
pub const ModuleHeader = struct {
    name: []const u8,
    exports: Filter = .all,
    /// The grammars a `for` clause names. Null for a grammar-generic module.
    grammars: ?[]const []const u8 = null,
    span: diagnostic.Span = .unknown,
};

/// `import A.B (x) as Q;`
pub const Import = struct {
    module: []const u8,
    /// What the import takes of the module's exports.
    selects: Filter = .all,
    /// Set when the import is qualified-only.
    qualifier: ?[]const u8 = null,
    span: diagnostic.Span = .unknown,
};

/// What an export or import list admits.
pub const Filter = union(enum) {
    all,
    only: []const Item,
    hiding: []const Item,
};

/// `x`, `T`, `T(..)` or `pattern P` in an export or import list.
pub const Item = struct {
    name: []const u8,
    kind: Kind,
    span: diagnostic.Span = .unknown,

    pub const Kind = enum { value, type, type_and_constructors, synonym };
};

/// `name :: type;` or `name p1 p2 = body;`.
pub const Declaration = union(enum) {
    signature: Signature,
    definition: Definition,
    data_declaration: DataDeclaration,
    type_alias: TypeAlias,
    pattern_synonym: PatternSynonym,
    pattern_signature: PatternSignature,
    class_declaration: ClassDeclaration,
    instance_declaration: InstanceDeclaration,

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

/// `name :: context => type;`, where the context may be absent.
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

/// `class Eq a => Describe a where { describe :: a -> String; };`
pub const ClassDeclaration = struct {
    name: Identifier,
    parameter: Identifier,
    superclasses: []const ClassConstraint = &.{},
    methods: []const Signature,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: ClassDeclaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(class {s} {s}", .{ self.name, self.parameter });
        try sexprContext(w, self.superclasses);
        for (self.methods) |m| {
            try w.writeByte(' ');
            try m.sexpr(w);
        }
        try w.writeByte(')');
    }
};

/// `instance Describe a => Describe [a] where { describe xs = ...; };`
pub const InstanceDeclaration = struct {
    class: Identifier,
    head: Type,
    context: []const ClassConstraint = &.{},
    methods: []const Definition,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: InstanceDeclaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(instance {s} ", .{self.class});
        try self.head.sexpr(w);
        try sexprContext(w, self.context);
        for (self.methods) |m| {
            try w.writeByte(' ');
            try m.sexpr(w);
        }
        try w.writeByte(')');
    }
};

fn sexprContext(w: *std.Io.Writer, context: []const ClassConstraint) std.Io.Writer.Error!void {
    if (context.len == 0) return;
    try w.writeAll(" (=>");
    for (context) |c| try w.print(" ({s} {s})", .{ c.class, c.variable });
    try w.writeByte(')');
}

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

/// `data T a = C1 f1 f2 | C2;`
pub const DataDeclaration = struct {
    name: Identifier,
    parameters: []const Identifier,
    constructors: []const ConstructorDeclaration,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: DataDeclaration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(data {s} (params", .{self.name});
        for (self.parameters) |p| try w.print(" {s}", .{p});
        try w.writeAll(")");
        for (self.constructors) |c| {
            try w.writeByte(' ');
            try c.sexpr(w);
        }
        try w.writeByte(')');
    }
};

/// `type T a = t;`
pub const TypeAlias = struct {
    name: Identifier,
    parameters: []const Identifier,
    type: Type,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: TypeAlias, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(type {s} (params", .{self.name});
        for (self.parameters) |p| try w.print(" {s}", .{p});
        try w.writeAll(") ");
        try self.type.sexpr(w);
        try w.writeByte(')');
    }
};

/// `pattern P x1 x2 <- p;`
pub const PatternSynonym = struct {
    name: Identifier,
    parameters: []const Parameter,
    body: Pattern,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: PatternSynonym, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(pattern {s} (params", .{self.name});
        for (self.parameters) |p| try w.print(" {s}", .{p.name});
        try w.writeAll(") ");
        try self.body.sexpr(w);
        try w.writeByte(')');
    }
};

/// `pattern P :: t;`
pub const PatternSignature = struct {
    name: Identifier,
    type: Type,
    span: diagnostic.Span = .unknown,

    pub fn sexpr(self: PatternSignature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(pattern_signature {s} ", .{self.name});
        try self.type.sexpr(w);
        try w.writeByte(')');
    }
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
    compose,
    then,
    cons,

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
            .compose => ".",
            .then => ">>",
            .cons => ":",
        };
    }
};

pub const Binary = struct {
    operator: BinaryOperator,
    left: Expression,
    right: Expression,
};

/// `(op)`, `(e op)` or `(op e)`.
pub const Section = struct {
    operator: SectionOperator,
    left: ?Expression,
    right: ?Expression,
};

pub const SectionOperator = union(enum) {
    binary: BinaryOperator,
    /// `$`, lowered as application.
    dollar,
    /// A backticked name: `` (`f` x) ``.
    function: Expression,
};

pub const Apply = struct {
    function: Expression,
    argument: Expression,
};

/// `n#field`, reading a grammar field of a node.
pub const Navigation = struct {
    /// Absent for a leading `#field`, whose node is the implicit input.
    node: ?Expression,
    field: Identifier,
};

/// `r.label`, reading a record field.
pub const Projection = struct {
    /// Absent for the section `_.label`, a function of the record.
    record: ?Expression,
    label: Identifier,
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
                try w.writeAll("(<- ");
                try b.pattern.sexpr(w);
                try w.writeByte(' ');
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
    pattern: Pattern,
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
        /// `:class_declaration`, carried without the leading colon.
        kind_test: Identifier,
        name: Identifier,
        number: i64,
        string: []const u8,
        boolean: bool,
        regex: []const u8,
        navigation: *Navigation,
        projection: *Projection,
        apply: *Apply,
        binary: *Binary,
        section: *Section,
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
        /// `of_shape p`: the filter keeping a value `p` matches.
        of_shape: *Pattern,
    };

    pub fn sexpr(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .kind_test => |k| try w.print("(kind {s})", .{k}),
            .name => |n| try w.print("{s}", .{n}),
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("(string \"{f}\")", .{string_literal.fmt(s)}),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .regex => |r| try w.print("(regex \"{s}\")", .{r}),
            .navigation => |n| {
                try w.writeAll("(field ");
                if (n.node) |subject| {
                    try subject.sexpr(w);
                } else {
                    try w.writeAll(".");
                }
                try w.print(" {s})", .{n.field});
            },
            .projection => |p| {
                try w.writeAll("(select ");
                if (p.record) |r| {
                    try r.sexpr(w);
                } else {
                    try w.writeAll("_");
                }
                try w.print(" {s})", .{p.label});
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
            .section => |s| {
                try w.writeAll("(section ");
                switch (s.operator) {
                    .binary => |o| try w.writeAll(o.spelling()),
                    .dollar => try w.writeAll("$"),
                    .function => |f| try f.sexpr(w),
                }
                for ([_]?Expression{ s.left, s.right }) |operand| {
                    try w.writeByte(' ');
                    if (operand) |o| try o.sexpr(w) else try w.writeAll("_");
                }
                try w.writeByte(')');
            },
            .case => |c| {
                try w.writeAll("(case ");
                try c.scrutinee.sexpr(w);
                for (c.alternatives) |a| {
                    try w.writeAll(" (alt ");
                    try a.pattern.sexpr(w);
                    if (a.guard) |g| {
                        try w.writeAll(" (if ");
                        try g.sexpr(w);
                        try w.writeByte(')');
                    }
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
            .of_shape => |p| {
                try w.writeAll("(of_shape ");
                try p.sexpr(w);
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

/// `{l: t, ...}`, or `{l: t, ... | r}` with the row `r` standing for any
/// further fields.
pub const RecordType = struct {
    fields: []const TypeField,
    row: ?Identifier = null,
};

/// `case e of { p -> e; p if g -> e; ... }`
pub const Case = struct {
    scrutinee: Expression,
    alternatives: []const Alternative,

    pub const Alternative = struct {
        pattern: Pattern,
        guard: ?Expression = null,
        body: Expression,
        span: diagnostic.Span = .unknown,
    };
};

/// The left side of a `case` alternative or a `do` bind.
pub const Pattern = struct {
    kind: Kind,
    span: diagnostic.Span = .unknown,

    pub const Kind = union(enum) {
        /// `x` binds the matched value. `_` binds nothing.
        variable: Identifier,
        constructor: Constructor,
        /// `[p, ...]`; `[]` is the empty list.
        list: []const Pattern,
        cons: *Cons,
        /// `x@p`
        as: *As,
        /// `p & q`
        conjunction: *Conjunction,
        /// `(e -> p)`
        view: *View,
        literal: Literal,
        /// `true` or `false`.
        boolean: bool,
        /// `:k { #f = p, .. }`, or `{ #f = p, .. }` with no kind.
        node: *Node,
    };

    pub const Node = struct {
        /// Carried without the leading colon.
        kind: ?Identifier,
        kind_span: diagnostic.Span = .unknown,
        fields: []const Field,

        pub const Field = struct {
            name: Identifier,
            name_span: diagnostic.Span = .unknown,
            pattern: Pattern,
            span: diagnostic.Span = .unknown,
        };
    };

    pub const Constructor = struct {
        name: Identifier,
        arguments: []const Pattern,
    };

    pub const Cons = struct {
        head: Pattern,
        tail: Pattern,
    };

    pub const As = struct {
        name: Identifier,
        name_span: diagnostic.Span = .unknown,
        pattern: Pattern,
    };

    pub const Conjunction = struct {
        left: Pattern,
        right: Pattern,
    };

    pub const View = struct {
        function: Expression,
        /// The view expression's source text.
        written: []const u8,
        pattern: Pattern,
    };

    /// Matched by `=` against the value, or by `~` for a regex.
    pub const Literal = union(enum) {
        number: i64,
        string: []const u8,
        regex: []const u8,
        /// A node kind, carried without the leading colon.
        kind: Identifier,
    };

    pub fn sexpr(self: Pattern, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .variable => |name| try w.writeAll(name),
            .as => |a| {
                try w.print("(@ {s} ", .{a.name});
                try a.pattern.sexpr(w);
                try w.writeByte(')');
            },
            .conjunction => |c| {
                try w.writeAll("(& ");
                try c.left.sexpr(w);
                try w.writeByte(' ');
                try c.right.sexpr(w);
                try w.writeByte(')');
            },
            .view => |v| {
                try w.writeAll("(view ");
                try v.function.sexpr(w);
                try w.writeByte(' ');
                try v.pattern.sexpr(w);
                try w.writeByte(')');
            },
            .literal => |l| switch (l) {
                .number => |n| try w.print("{d}", .{n}),
                .string => |s| try w.print("(string \"{f}\")", .{string_literal.fmt(s)}),
                .regex => |r| try w.print("(regex \"{s}\")", .{r}),
                .kind => |k| try w.print("(kind {s})", .{k}),
            },
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .node => |n| {
                try w.writeAll("(node");
                if (n.kind) |k| try w.print(" (kind {s})", .{k});
                for (n.fields) |f| {
                    try w.print(" (#{s} ", .{f.name});
                    try f.pattern.sexpr(w);
                    try w.writeByte(')');
                }
                try w.writeByte(')');
            },
            .constructor => |c| {
                if (c.arguments.len == 0) return w.writeAll(c.name);
                try w.print("({s}", .{c.name});
                for (c.arguments) |argument| {
                    try w.writeByte(' ');
                    try argument.sexpr(w);
                }
                try w.writeByte(')');
            },
            .list => |elements| {
                try w.writeAll("(list");
                for (elements) |element| {
                    try w.writeByte(' ');
                    try element.sexpr(w);
                }
                try w.writeByte(')');
            },
            .cons => |c| {
                try w.writeAll("(: ");
                try c.head.sexpr(w);
                try w.writeByte(' ');
                try c.tail.sexpr(w);
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
        record: RecordType,
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
            .record => |r| {
                try w.writeAll("(record_type");
                for (r.fields) |f| {
                    try w.print(" ({s} ", .{f.name});
                    try f.type.sexpr(w);
                    try w.writeByte(')');
                }
                if (r.row) |row| try w.print(" | {s}", .{row});
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
