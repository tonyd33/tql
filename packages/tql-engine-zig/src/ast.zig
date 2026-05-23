const std = @import("std");

pub const Identifier = []const u8;

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
    query_body: QueryBody,

    pub fn deinit(self: SourceItem, allocator: std.mem.Allocator) void {
        switch (self) {
            .directive => |d| d.deinit(allocator),
            .query => |q| q.deinit(allocator),
            .query_body => |q| q.deinit(allocator),
        }
    }

    pub fn sexpr(self: SourceItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .directive => |d| try d.sexpr(w),
            .query => |q| try q.sexpr(w),
            .query_body => |qb| try qb.sexpr(w),
        }
    }
};

pub const QueryDefinition = struct {
    name: Identifier,
    parameters: []const Parameter,
    return_type: ?Type,
    body: QueryBody,

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

pub const QueryBody = struct {
    with_clause: ?WithClause,
    where_clause: ?WhereClause,
    select_clause: SelectClause,

    pub fn deinit(self: QueryBody, allocator: std.mem.Allocator) void {
        if (self.with_clause) |fc| {
            fc.deinit(allocator);
        }
        if (self.where_clause) |wc| {
            wc.deinit(allocator);
        }
        self.select_clause.deinit(allocator);
    }

    pub fn sexpr(self: QueryBody, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(query_body");
        if (self.with_clause) |fc| {
            try w.writeByte(' ');
            try fc.sexpr(w);
        }
        if (self.where_clause) |wc| {
            try w.writeByte(' ');
            try wc.sexpr(w);
        }
        try w.writeByte(' ');
        try self.select_clause.sexpr(w);
        try w.writeByte(')');
    }
};

pub const WithClause = struct {
    bindings: []const Binding,

    pub fn deinit(self: WithClause, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            binding.deinit(allocator);
        }
        allocator.free(self.bindings);
    }

    pub fn sexpr(self: WithClause, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(with");
        for (self.bindings) |b| {
            try w.writeByte(' ');
            try b.sexpr(w);
        }
        try w.writeByte(')');
    }
};

pub const Binding = struct {
    expression: Expression,
    variable: Variable,
    optional: bool,

    pub fn deinit(self: Binding, allocator: std.mem.Allocator) void {
        self.expression.deinit(allocator);
        allocator.free(self.variable.name);
    }

    pub fn sexpr(self: Binding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(binding ");
        try self.expression.sexpr(w);
        try w.print(" {s}", .{self.variable.name});
        if (self.optional) try w.writeAll(" optional");
        try w.writeByte(')');
    }
};

pub const NodeSelector = struct {
    node_type: Identifier,
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

pub const WhereClause = struct {
    predicate: Predicate,

    pub fn deinit(self: WhereClause, allocator: std.mem.Allocator) void {
        self.predicate.deinit(allocator);
    }

    pub fn sexpr(self: WhereClause, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(where ");
        try self.predicate.sexpr(w);
        try w.writeByte(')');
    }
};

pub const Predicate = union(enum) {
    comparison: Comparison,
    is_null: IsNullPredicate,
    logical_and: *LogicalAnd,
    logical_or: *LogicalOr,
    logical_not: *LogicalNot,
    quantified: QuantifiedExpression,
    parenthesized: *Predicate,

    pub fn deinit(self: Predicate, allocator: std.mem.Allocator) void {
        switch (self) {
            .comparison => |c| {
                c.left.deinit(allocator);
                c.right.deinit(allocator);
            },
            .is_null => |p| {
                p.expression.deinit(allocator);
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
            .quantified => |q| {
                allocator.free(q.variable.name);
                q.source.deinit(allocator);
                q.predicate.deinit(allocator);
                allocator.destroy(q.predicate);
            },
            .parenthesized => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
        }
    }

    pub fn sexpr(self: Predicate, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
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
            .quantified => |q| {
                try w.print("({s} {s} ", .{ @tagName(q.quantifier), q.variable.name });
                try q.source.sexpr(w);
                try w.writeByte(' ');
                try q.predicate.sexpr(w);
                try w.writeByte(')');
            },
            .parenthesized => |p| {
                try w.writeAll("(paren ");
                try p.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

pub const Comparison = struct {
    left: Expression,
    operator: ComparisonOperator,
    right: Expression,
};

pub const IsNullPredicate = struct {
    expression: Expression,
    negated: bool,
};

pub const ComparisonOperator = enum {
    eq,
    ne,
    regex_match,
    regex_not_match,
    gt,
    lt,
    gte,
    lte,
};

pub const LogicalAnd = struct {
    left: Predicate,
    right: Predicate,
};

pub const LogicalOr = struct {
    left: Predicate,
    right: Predicate,
};

pub const LogicalNot = struct {
    predicate: Predicate,
};

pub const QuantifiedExpression = struct {
    quantifier: Quantifier,
    variable: Variable,
    source: Expression,
    predicate: *Predicate,
};

pub const Quantifier = enum {
    any,
    all,
};

pub const Projection = Expression;

pub const SelectClause = struct {
    projection: Projection,

    pub fn deinit(self: SelectClause, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
    }

    pub fn sexpr(self: SelectClause, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(select ");
        try self.projection.sexpr(w);
        try w.writeByte(')');
    }
};

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

pub const Expression = union(enum) {
    node_selector: NodeSelector,
    variable: Variable,
    string_literal: []const u8,
    regex_literal: []const u8,
    number_literal: u64,
    null_literal,
    field_access: *FieldAccess,
    child_navigation: *ChildNavigation,
    descendant_navigation: *DescendantNavigation,
    function_call: FunctionCall,
    object_literal: ObjectLiteral,
    array_literal: ArrayLiteral,
    tuple_literal: TupleLiteral,
    subquery: *QueryBody,
    parenthesized: *Expression,

    pub fn deinit(self: Expression, allocator: std.mem.Allocator) void {
        switch (self) {
            .node_selector => |ns| allocator.free(ns.node_type),
            .variable => |v| allocator.free(v.name),
            .string_literal => |s| allocator.free(s),
            .regex_literal => |r| allocator.free(r),
            .number_literal => {},
            .null_literal => {},
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
                allocator.free(fc.name);
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
            .subquery => |sq| {
                sq.deinit(allocator);
                allocator.destroy(sq);
            },
            .parenthesized => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
        }
    }

    pub fn sexpr(self: Expression, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .node_selector => |ns| try w.print("(node {s})", .{ns.node_type}),
            .variable => |v| try w.print("{s}", .{v.name}),
            .string_literal => |s| try w.print("(string \"{s}\")", .{s}),
            .regex_literal => |r| try w.print("(regex \"{s}\")", .{r}),
            .number_literal => |n| try w.print("(number {d})", .{n}),
            .null_literal => try w.writeAll("null"),
            .field_access => |fa| try fa.sexpr(w),
            .child_navigation => |cn| try cn.sexpr(w),
            .descendant_navigation => |dn| try dn.sexpr(w),
            .function_call => |fc| try fc.sexpr(w),
            .object_literal => |ol| try ol.sexpr(w),
            .array_literal => |al| try al.sexpr(w),
            .tuple_literal => |tl| try tl.sexpr(w),
            .subquery => |sq| {
                try w.writeAll("(subquery ");
                try sq.sexpr(w);
                try w.writeByte(')');
            },
            .parenthesized => |pe| {
                try w.writeAll("(paren ");
                try pe.sexpr(w);
                try w.writeByte(')');
            },
        }
    }
};

pub const FunctionCall = struct {
    name: Identifier,
    arguments: []const Expression,

    pub fn sexpr(self: FunctionCall, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(call {s}", .{self.name});
        for (self.arguments) |arg| {
            try w.writeByte(' ');
            try arg.sexpr(w);
        }
        try w.writeByte(')');
    }
};

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
