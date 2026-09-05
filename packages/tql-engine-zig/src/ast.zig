const std = @import("std");

pub const Identifier = []const u8;

/// Byte range in the TQL source, half-open: `[start, end)`.
pub const Span = struct {
    start: u32,
    end: u32,

    /// For nodes that no source range corresponds to.
    pub const unknown: Span = .{ .start = 0, .end = 0 };

    pub fn sexpr(self: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ self.start, self.end });
    }
};

pub const Variable = struct {
    name: Identifier,
};

pub const Directive = union(enum) {
    language: LanguageDirective,
    import: ImportDirective,

    pub fn deinit(self: Directive, allocator: std.mem.Allocator) void {
        switch (self) {
            .language => |l| allocator.free(l.language),
            .import => |i| allocator.free(i.path),
        }
    }

    pub fn sexpr(self: Directive, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .language => |l| try w.print("(language \"{s}\")", .{l.language}),
            .import => |i| try w.print("(import \"{s}\")", .{i.path}),
        }
    }
};

pub const LanguageDirective = struct {
    language: []const u8,
};

pub const ImportDirective = struct {
    path: []const u8,
};

pub const SourceFile = struct {
    items: []const SourceItem,

    pub fn deinit(self: SourceFile, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }

    pub fn sexpr(self: SourceFile, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(source_file");
        for (self.items) |item| {
            try w.writeByte(' ');
            try item.sexpr(w);
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

pub const SourceItem = union(enum) {
    directive: Directive,
    query: QueryDefinition,
    expression: Expression,

    pub fn deinit(self: SourceItem, allocator: std.mem.Allocator) void {
        switch (self) {
            .directive => |d| d.deinit(allocator),
            .query => |q| q.deinit(allocator),
            .expression => |e| e.deinit(allocator),
        }
    }

    pub fn sexpr(self: SourceItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .directive => |d| try d.sexpr(w),
            .query => |q| try q.sexpr(w),
            .expression => |e| try e.sexpr(w),
        }
    }
};

pub const QueryDefinition = struct {
    name: Identifier,
    parameters: []const Parameter,
    return_type: ?Type,
    body: Expression,

    pub fn deinit(self: QueryDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.parameters) |param| {
            param.deinit(allocator);
        }
        allocator.free(self.parameters);
        if (self.return_type) |rt| {
            rt.deinit(allocator);
        }
        self.body.deinit(allocator);
    }

    pub fn sexpr(self: QueryDefinition, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(query {s} (parameters", .{self.name});
        for (self.parameters) |p| {
            try w.writeByte(' ');
            try p.sexpr(w);
        }
        try w.writeByte(')');
        if (self.return_type) |rt| {
            try w.writeAll(" (return_type ");
            try rt.sexpr(w);
            try w.writeByte(')');
        }
        try w.writeByte(' ');
        try self.body.sexpr(w);
        try w.writeByte(')');
    }
};

pub const Parameter = struct {
    name: Variable,
    type: ?Type,

    pub fn deinit(self: Parameter, allocator: std.mem.Allocator) void {
        allocator.free(self.name.name);
        if (self.type) |t| {
            t.deinit(allocator);
        }
    }

    pub fn sexpr(self: Parameter, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(param {s}", .{self.name.name});
        if (self.type) |t| {
            try w.writeByte(' ');
            try t.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const BindExpression = struct {
    expression: Expression,
    variable: Variable,
    optional: bool,

    pub fn deinit(self: BindExpression, allocator: std.mem.Allocator) void {
        self.expression.deinit(allocator);
        allocator.free(self.variable.name);
    }

    pub fn sexpr(self: BindExpression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(bind ");
        try self.expression.sexpr(w);
        try w.print(" {s}", .{self.variable.name});
        if (self.optional) try w.writeAll(" optional");
        try w.writeByte(')');
    }
};

pub const LetBinding = struct {
    variable: Variable,
    value: Expression,

    pub fn deinit(self: LetBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.variable.name);
        self.value.deinit(allocator);
    }

    pub fn sexpr(self: LetBinding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({s} ", .{self.variable.name});
        try self.value.sexpr(w);
        try w.writeByte(')');
    }
};

pub const LetExpression = struct {
    bindings: []const LetBinding,
    body: Expression,

    pub fn deinit(self: LetExpression, allocator: std.mem.Allocator) void {
        for (self.bindings) |b| b.deinit(allocator);
        allocator.free(self.bindings);
        self.body.deinit(allocator);
    }

    pub fn sexpr(self: LetExpression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(let (");
        for (self.bindings, 0..) |b, i| {
            if (i > 0) try w.writeByte(' ');
            try b.sexpr(w);
        }
        try w.writeAll(") ");
        try self.body.sexpr(w);
        try w.writeByte(')');
    }
};

pub const PipeExpression = struct {
    left: Expression,
    right: Expression,

    pub fn sexpr(self: PipeExpression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(pipe ");
        try self.left.sexpr(w);
        try w.writeByte(' ');
        try self.right.sexpr(w);
        try w.writeByte(')');
    }
};

pub const UnionExpression = struct {
    left: Expression,
    right: Expression,

    pub fn sexpr(self: UnionExpression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(union ");
        try self.left.sexpr(w);
        try w.writeByte(' ');
        try self.right.sexpr(w);
        try w.writeByte(')');
    }
};

// ============================================================================
// Navigation
// ============================================================================

pub const NodeSelector = union(enum) {
    kind: Identifier,
    wildcard,
};

pub const FieldAccess = struct {
    base: Expression,
    field: Identifier,

    pub fn sexpr(self: FieldAccess, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(field ");
        try self.base.sexpr(w);
        try w.print(" {s})", .{self.field});
    }
};

pub const ChildNavigation = struct {
    parent: Expression,
    child: Expression,

    pub fn sexpr(self: ChildNavigation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(child ");
        try self.parent.sexpr(w);
        try w.writeByte(' ');
        try self.child.sexpr(w);
        try w.writeByte(')');
    }
};

pub const DescendantNavigation = struct {
    parent: Expression,
    descendant: Expression,

    pub fn sexpr(self: DescendantNavigation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(descendant ");
        try self.parent.sexpr(w);
        try w.writeByte(' ');
        try self.descendant.sexpr(w);
        try w.writeByte(')');
    }
};

// ============================================================================
// Boolean / guard expressions (formerly Predicate)
// ============================================================================

pub const Comparison = struct {
    left: Expression,
    operator: ComparisonOperator,
    right: Expression,
};

pub const IsNullExpr = struct {
    expression: Expression,
    negated: bool,
};

pub const ComparisonOperator = enum {
    eq,
    ne,
    regex_match,
    regex_not_match,
    lt,
    gt,
    lte,
    gte,
};

pub const LogicalAnd = struct {
    left: Expression,
    right: Expression,
};

pub const LogicalOr = struct {
    left: Expression,
    right: Expression,
};

pub const LogicalNot = struct {
    predicate: Expression,
};

// ============================================================================
// Expressions
// ============================================================================

pub const ObjectLiteral = struct {
    fields: []const ObjectField,

    pub fn sexpr(self: ObjectLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(object");
        for (self.fields) |f| {
            try w.writeByte(' ');
            try f.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const ObjectField = union(enum) {
    variable: Variable,
    key_value: struct {
        key: Identifier,
        value: Expression,
    },

    pub fn deinit(self: ObjectField, allocator: std.mem.Allocator) void {
        switch (self) {
            .variable => |v| allocator.free(v.name),
            .key_value => |kv| {
                allocator.free(kv.key);
                kv.value.deinit(allocator);
            },
        }
    }

    pub fn sexpr(self: ObjectField, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .variable => |v| try w.print("{s}", .{v.name}),
            .key_value => |kv| {
                try w.print("({s} ", .{kv.key});
                try kv.value.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

pub const ArrayLiteral = struct {
    elements: []const Expression,

    pub fn sexpr(self: ArrayLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(array");
        for (self.elements) |e| {
            try w.writeByte(' ');
            try e.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const TupleLiteral = struct {
    elements: []const Expression,

    pub fn sexpr(self: TupleLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(tuple");
        for (self.elements) |e| {
            try w.writeByte(' ');
            try e.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const DotFieldAccess = struct {
    field: Identifier,

    pub fn sexpr(self: DotFieldAccess, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(dot-field {s})", .{self.field});
    }
};

pub const Expression = struct {
    kind: Kind,
    span: Span = .unknown,

    pub const Kind = union(enum) {
        node_selector: NodeSelector,
        variable: Variable,
        dot_field_access: DotFieldAccess,
        string_literal: []const u8,
        regex_literal: []const u8,
        number_literal: i64,
        null_literal,
        identity,
        field_access: *FieldAccess,
        child_navigation: *ChildNavigation,
        descendant_navigation: *DescendantNavigation,
        function_call: FunctionCall,
        object_literal: ObjectLiteral,
        array_literal: ArrayLiteral,
        tuple_literal: TupleLiteral,
        parenthesized: *Expression,
        collect_expression: *Expression,
        bind_expression: *BindExpression,
        let_expression: *LetExpression,
        pipe_expression: *PipeExpression,
        union_expression: *UnionExpression,
        comparison: *Comparison,
        is_null: *IsNullExpr,
        logical_and: *LogicalAnd,
        logical_or: *LogicalOr,
        logical_not: *LogicalNot,
    };

    pub fn deinit(self: Expression, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .node_selector => |ns| switch (ns) {
                .kind => |k| allocator.free(k),
                .wildcard => {},
            },
            .variable => |v| allocator.free(v.name),
            .dot_field_access => |dfa| allocator.free(dfa.field),
            .string_literal => |s| allocator.free(s),
            .regex_literal => |r| allocator.free(r),
            .number_literal => {},
            .null_literal => {},
            .identity => {},
            .field_access => |fa| {
                fa.base.deinit(allocator);
                allocator.free(fa.field);
                allocator.destroy(fa);
            },
            .child_navigation => |cn| {
                cn.parent.deinit(allocator);
                cn.child.deinit(allocator);
                allocator.destroy(cn);
            },
            .descendant_navigation => |dn| {
                dn.parent.deinit(allocator);
                dn.descendant.deinit(allocator);
                allocator.destroy(dn);
            },
            .function_call => |fc| {
                switch (fc.callee) {
                    .name => |name| allocator.free(name),
                    .variable => |name| allocator.free(name),
                }
                for (fc.arguments) |arg| arg.deinit(allocator);
                allocator.free(fc.arguments);
            },
            .object_literal => |ol| {
                for (ol.fields) |field| field.deinit(allocator);
                allocator.free(ol.fields);
            },
            .array_literal => |al| {
                for (al.elements) |elem| elem.deinit(allocator);
                allocator.free(al.elements);
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| elem.deinit(allocator);
                allocator.free(tl.elements);
            },
            .parenthesized => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
            .collect_expression => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
            .bind_expression => |be| {
                be.deinit(allocator);
                allocator.destroy(be);
            },
            .let_expression => |le| {
                le.deinit(allocator);
                allocator.destroy(le);
            },
            .pipe_expression => |pe| {
                pe.left.deinit(allocator);
                pe.right.deinit(allocator);
                allocator.destroy(pe);
            },
            .union_expression => |ue| {
                ue.left.deinit(allocator);
                ue.right.deinit(allocator);
                allocator.destroy(ue);
            },
            .comparison => |c| {
                c.left.deinit(allocator);
                c.right.deinit(allocator);
                allocator.destroy(c);
            },
            .is_null => |p| {
                p.expression.deinit(allocator);
                allocator.destroy(p);
            },
            .logical_and => |la| {
                la.left.deinit(allocator);
                la.right.deinit(allocator);
                allocator.destroy(la);
            },
            .logical_or => |lo| {
                lo.left.deinit(allocator);
                lo.right.deinit(allocator);
                allocator.destroy(lo);
            },
            .logical_not => |ln| {
                ln.predicate.deinit(allocator);
                allocator.destroy(ln);
            },
        }
    }

    pub fn sexpr(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .node_selector => |ns| switch (ns) {
                .kind => |k| try w.print("(node {s})", .{k}),
                .wildcard => try w.writeAll("(node *)"),
            },
            .variable => |v| try w.print("{s}", .{v.name}),
            .dot_field_access => |dfa| try dfa.sexpr(w),
            .string_literal => |s| try w.print("(string \"{s}\")", .{s}),
            .regex_literal => |r| try w.print("(regex \"{s}\")", .{r}),
            .number_literal => |n| try w.print("(number {d})", .{n}),
            .null_literal => try w.writeAll("null"),
            .identity => try w.writeAll("."),
            .field_access => |fa| try fa.sexpr(w),
            .child_navigation => |cn| try cn.sexpr(w),
            .descendant_navigation => |dn| try dn.sexpr(w),
            .function_call => |fc| try fc.sexpr(w),
            .object_literal => |ol| try ol.sexpr(w),
            .array_literal => |al| try al.sexpr(w),
            .tuple_literal => |tl| try tl.sexpr(w),
            .parenthesized => |pe| {
                try w.writeAll("(paren ");
                try pe.sexpr(w);
                try w.writeByte(')');
            },
            .collect_expression => |pe| {
                try w.writeAll("(collect ");
                try pe.sexpr(w);
                try w.writeByte(')');
            },
            .bind_expression => |be| try be.sexpr(w),
            .let_expression => |le| try le.sexpr(w),
            .pipe_expression => |pe| try pe.sexpr(w),
            .union_expression => |ue| try ue.sexpr(w),
            .comparison => |c| {
                try w.print("({s} ", .{@tagName(c.operator)});
                try c.left.sexpr(w);
                try w.writeByte(' ');
                try c.right.sexpr(w);
                try w.writeByte(')');
            },
            .is_null => |p| {
                try w.writeAll(if (p.negated) "(is-not-null " else "(is-null ");
                try p.expression.sexpr(w);
                try w.writeByte(')');
            },
            .logical_and => |la| {
                try w.writeAll("(and ");
                try la.left.sexpr(w);
                try w.writeByte(' ');
                try la.right.sexpr(w);
                try w.writeByte(')');
            },
            .logical_or => |lo| {
                try w.writeAll("(or ");
                try lo.left.sexpr(w);
                try w.writeByte(' ');
                try lo.right.sexpr(w);
                try w.writeByte(')');
            },
            .logical_not => |ln| {
                try w.writeAll("(not ");
                try ln.predicate.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

pub const FunctionCallCallee = union(enum) {
    name: Identifier,
    variable: Identifier,
};

pub const FunctionCall = struct {
    callee: FunctionCallCallee,
    arguments: []const Expression,

    pub fn sexpr(self: FunctionCall, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.callee) {
            .name => |name| try w.print("(call {s}", .{name}),
            .variable => |name| try w.print("(call @{s}", .{name}),
        }
        for (self.arguments) |arg| {
            try w.writeByte(' ');
            try arg.sexpr(w);
        }
        try w.writeByte(')');
    }
};

// ============================================================================
// Types
// ============================================================================

pub const Type = union(enum) {
    identifier: Identifier,
    builtin: BuiltinType,
    array: ArrayType,
    object: ObjectType,
    tuple: TupleType,
    optional: *Type,

    pub fn deinit(self: Type, allocator: std.mem.Allocator) void {
        switch (self) {
            .identifier => |i| allocator.free(i),
            .builtin => {},
            .array => |at| {
                at.element_type.deinit(allocator);
                allocator.destroy(at.element_type);
            },
            .object => |ot| {
                ot.value_type.deinit(allocator);
                allocator.destroy(ot.value_type);
            },
            .tuple => |tt| {
                for (tt.element_types) |et| {
                    et.deinit(allocator);
                }
                allocator.free(tt.element_types);
            },
            .optional => |opt| {
                opt.deinit(allocator);
                allocator.destroy(opt);
            },
        }
    }

    pub fn sexpr(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .identifier => |i| try w.print("{s}", .{i}),
            .builtin => |b| try w.print("{s}", .{@tagName(b)}),
            .array => |at| {
                try w.writeAll("(array_type ");
                try at.element_type.sexpr(w);
                try w.writeByte(')');
            },
            .object => |ot| {
                try w.writeAll("(object_type ");
                try ot.value_type.sexpr(w);
                try w.writeByte(')');
            },
            .tuple => |tt| {
                try w.writeAll("(tuple_type");
                for (tt.element_types) |et| {
                    try w.writeByte(' ');
                    try et.sexpr(w);
                }
                try w.writeByte(')');
            },
            .optional => |opt| {
                try w.writeAll("(optional ");
                try opt.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

pub const BuiltinType = enum {
    string,
    number,
    boolean,
    regex,
};

pub const ArrayType = struct {
    element_type: *Type,
};

pub const ObjectType = struct {
    value_type: *Type,
};

pub const TupleType = struct {
    element_types: []const Type,
};
