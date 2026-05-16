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
};

pub const QueryBody = struct {
    from_clause: ?FromClause,
    where_clause: ?WhereClause,
    select_clause: SelectClause,

    pub fn deinit(self: QueryBody, allocator: std.mem.Allocator) void {
        if (self.from_clause) |fc| {
            fc.deinit(allocator);
        }
        if (self.where_clause) |wc| {
            wc.deinit(allocator);
        }
        self.select_clause.deinit(allocator);
    }
};

pub const FromClause = struct {
    bindings: []const Binding,

    pub fn deinit(self: FromClause, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| {
            binding.deinit(allocator);
        }
        allocator.free(self.bindings);
    }
};

pub const Binding = struct {
    expression: NavigationExpression,
    variable: Variable,
    optional: bool,

    pub fn deinit(self: Binding, allocator: std.mem.Allocator) void {
        self.expression.deinit(allocator);
        allocator.free(self.variable.name);
    }
};

pub const NavigationExpression = union(enum) {
    node_selector: NodeSelector,
    variable: Variable,
    field_access: *FieldAccess,
    child_navigation: *ChildNavigation,
    descendant_navigation: *DescendantNavigation,
    query_call: *QueryCall,
    parenthesized: *NavigationExpression,

    pub fn deinit(self: NavigationExpression, allocator: std.mem.Allocator) void {
        switch (self) {
            .node_selector => |ns| allocator.free(ns.node_type),
            .variable => |v| allocator.free(v.name),
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
            .query_call => |qc| {
                allocator.free(qc.name);
                for (qc.arguments) |arg| {
                    arg.deinit(allocator);
                }
                allocator.free(qc.arguments);
                allocator.destroy(qc);
            },
            .parenthesized => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
        }
    }
};

pub const NodeSelector = struct {
    node_type: Identifier,
};

pub const FieldAccess = struct {
    base: NavigationExpression,
    field: Identifier,
};

pub const ChildNavigation = struct {
    parent: NavigationExpression,
    child: NavigationExpression,
};

pub const DescendantNavigation = struct {
    parent: NavigationExpression,
    descendant: NavigationExpression,
};

pub const QueryCall = struct {
    name: Identifier,
    arguments: []const Expression,
};

pub const WhereClause = struct {
    predicate: Predicate,

    pub fn deinit(self: WhereClause, allocator: std.mem.Allocator) void {
        self.predicate.deinit(allocator);
    }
};

pub const Predicate = union(enum) {
    comparison: Comparison,
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
                q.predicate.deinit(allocator);
                allocator.destroy(q.predicate);
            },
            .parenthesized => |p| {
                p.deinit(allocator);
                allocator.destroy(p);
            },
        }
    }
};

pub const Comparison = struct {
    left: Expression,
    operator: ComparisonOperator,
    right: Expression,
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
    predicate: *Predicate,
};

pub const Quantifier = enum {
    forall,
    exists,
};

pub const SelectClause = struct {
    projection: Projection,

    pub fn deinit(self: SelectClause, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
    }
};

pub const Projection = union(enum) {
    variable: Variable,
    string_literal: []const u8,
    regex_literal: []const u8,
    number_literal: f64,
    function_call: FunctionCall,
    field_access: *FieldAccessExpression,
    object_literal: ObjectLiteral,
    array_literal: ArrayLiteral,
    tuple_literal: TupleLiteral,
    subquery: *QueryBody,

    pub fn deinit(self: Projection, allocator: std.mem.Allocator) void {
        switch (self) {
            .variable => |v| allocator.free(v.name),
            .string_literal => |s| allocator.free(s),
            .regex_literal => |r| allocator.free(r),
            .number_literal => {},
            .function_call => |fc| {
                allocator.free(fc.name);
                for (fc.arguments) |arg| {
                    arg.deinit(allocator);
                }
                allocator.free(fc.arguments);
            },
            .field_access => |fa| {
                fa.base.deinit(allocator);
                allocator.free(fa.field);
                allocator.destroy(fa);
            },
            .object_literal => |ol| {
                for (ol.fields) |field| {
                    field.deinit(allocator);
                }
                allocator.free(ol.fields);
            },
            .array_literal => |al| {
                for (al.elements) |elem| {
                    elem.deinit(allocator);
                }
                allocator.free(al.elements);
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    elem.deinit(allocator);
                }
                allocator.free(tl.elements);
            },
            .subquery => |sq| {
                sq.deinit(allocator);
                allocator.destroy(sq);
            },
        }
    }
};

pub const ObjectLiteral = struct {
    fields: []const ObjectField,
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
};

pub const ArrayLiteral = struct {
    elements: []const Expression,
};

pub const TupleLiteral = struct {
    elements: []const Expression,
};

pub const Expression = union(enum) {
    variable: Variable,
    string_literal: []const u8,
    regex_literal: []const u8,
    number_literal: f64,
    null_literal,
    function_call: FunctionCall,
    field_access: *FieldAccessExpression,
    object_literal: ObjectLiteral,
    array_literal: ArrayLiteral,
    tuple_literal: TupleLiteral,
    subquery: *QueryBody,

    pub fn deinit(self: Expression, allocator: std.mem.Allocator) void {
        switch (self) {
            .variable => |v| allocator.free(v.name),
            .string_literal => |s| allocator.free(s),
            .regex_literal => |r| allocator.free(r),
            .number_literal => {},
            .null_literal => {},
            .function_call => |fc| {
                allocator.free(fc.name);
                for (fc.arguments) |arg| arg.deinit(allocator);
                allocator.free(fc.arguments);
            },
            .field_access => |fa| {
                fa.base.deinit(allocator);
                allocator.free(fa.field);
                allocator.destroy(fa);
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
        }
    }
};

pub const FunctionCall = struct {
    name: Identifier,
    arguments: []const Expression,
};

pub const FieldAccessExpression = struct {
    base: Expression,
    field: Identifier,
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

