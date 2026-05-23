const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const runtime = @import("runtime.zig");
const Condition = runtime.Condition;
const Instruction = runtime.Instruction;
const VariableId = runtime.VariableId;
const NodeKindId = runtime.NodeKindId;
const FieldId = runtime.FieldId;
const Address = runtime.Address;
const Relation = runtime.Relation;
const ProgramImage = runtime.ProgramImage;

const ast = @import("ast.zig");
const pcre2 = @import("pcre2.zig");

pub const VariableTable = @import("compiler/variable_table.zig").VariableTable;
pub const InstructionBuilder = @import("compiler/instruction_builder.zig").InstructionBuilder;
const CompilerError = @import("compiler/types.zig").CompilerError;

const LabelId = u32;

const BindingMetadata = struct {
    variable_id: VariableId,
    expression: ast.Expression,
    emitted: bool = false,
};

// FIXME: Please don't do this...
const ROOT_NAME = &[_]u8{0};

pub const Compiler = struct {
    allocator: Allocator,
    variables: VariableTable,
    language: *ts.Language,
    bindings: std.ArrayList(BindingMetadata),

    regexes: std.ArrayList(pcre2.Regex),
    strings: std.ArrayList([]const u8),

    // FIXME: we're supposed to detect the language
    pub fn init(allocator: Allocator, language: *ts.Language) Compiler {
        return .{
            .allocator = allocator,
            .variables = VariableTable.init(allocator),
            .language = language,
            .bindings = std.ArrayList(BindingMetadata){},
            .regexes = std.ArrayList(pcre2.Regex){},
            .strings = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.variables.deinit();
        self.bindings.deinit(self.allocator);

        for (self.regexes.items) |*regex| {
            regex.deinit();
        }
        self.regexes.deinit(self.allocator);

        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn addRegex(self: *Compiler, regex: pcre2.Regex) CompilerError!usize {
        const index = self.regexes.items.len;
        try self.regexes.append(self.allocator, regex);
        return index;
    }

    pub fn addString(self: *Compiler, str: []const u8) CompilerError![]const u8 {
        // IMPROVE: consider interning the strings
        const owned = try self.allocator.dupe(u8, str);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    pub fn compile(self: *Compiler, allocator: std.mem.Allocator, source: ast.SourceFile) CompilerError!ProgramImage {
        var builder = InstructionBuilder.init(self.allocator);
        defer builder.deinit();

        // FIXME: we're supposed to search for main
        // It would be nice if we can compile just the query body though, since that gives
        // a valid program.
        for (source.items) |item| {
            switch (item) {
                .query => |query| try self.compileQueryBody(&builder, query.body),
                .query_body => |query_body| try self.compileQueryBody(&builder, query_body),
                else => {
                    @panic("Not implemented");
                },
            }
        }

        var variable_iterator = self.variables.map.iterator();
        var variable_map = std.hash_map.AutoHashMap(runtime.VariableId, []const u8).init(allocator);
        while (variable_iterator.next()) |entry| {
            const slice = try self.addString(entry.key_ptr.*);
            try variable_map.put(entry.value_ptr.*, slice);
        }

        const instructions = try builder.patch(allocator);
        const regexes = try self.regexes.toOwnedSlice(allocator);
        const strings = try self.strings.toOwnedSlice(allocator);
        return .{
            .instructions = instructions,
            .regexes = regexes,
            .strings = strings,
            .variable_map = variable_map,
            .allocator = allocator,
        };
    }

    fn compileQueryBody(self: *Compiler, builder: *InstructionBuilder, body: ast.QueryBody) !void {
        const root_id = try self.variables.getOrPut(ROOT_NAME);
        try builder.emit(.{ .asn = .{
            .variable_id = root_id,
            .source = .{ .node = .this },
        } });

        if (body.with_clause) |with_clause| {
            try self.compileWithClause(with_clause);
        }

        if (body.where_clause) |where_clause| {
            try self.compileWhereClause(builder, where_clause);
        }

        try self.compileSelectClause(builder, body.select_clause);
        try builder.emit(.{ .halt = .{ .condition = .always } });
    }

    fn compileWithClause(self: *Compiler, with_clause: ast.WithClause) CompilerError!void {
        for (with_clause.bindings) |binding| {
            try self.compileBinding(binding);
        }
    }

    fn compileBinding(self: *Compiler, binding: ast.Binding) CompilerError!void {
        const var_id = try self.variables.getOrPut(binding.variable.name);

        try self.bindings.append(self.allocator, .{
            .variable_id = var_id,
            .expression = binding.expression,
            .emitted = false,
        });
    }

    fn ensureRootNavigated(self: *Compiler, builder: *InstructionBuilder) CompilerError!void {
        const root_id = self.variables.get(ROOT_NAME) orelse return error.InvalidVariableReference;
        try builder.emit(.{ .trv = .{ .variable_id = root_id } });
    }

    fn ensureVariableNavigated(self: *Compiler, builder: *InstructionBuilder, var_id: VariableId) CompilerError!void {
        for (self.bindings.items) |*binding| {
            if (binding.variable_id == var_id) {
                if (binding.emitted) return;

                try self.ensureExpressionDependencies(builder, binding.expression);
                try self.compileAsNavigation(builder, binding.expression);
                try builder.emit(.{ .asn = .{
                    .variable_id = var_id,
                    .source = .{ .node = .this },
                } });
                binding.emitted = true;
                return;
            }
        }
        return error.InvalidVariableReference;
    }

    fn ensureExpressionDependencies(self: *Compiler, builder: *InstructionBuilder, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                const dep_var_id = self.variables.get(variable.name) orelse return error.InvalidVariableReference;
                try self.ensureVariableNavigated(builder, dep_var_id);
            },
            .field_access => |field_access| {
                switch (field_access.base) {
                    .variable => |variable| {
                        const dep_var_id = self.variables.get(variable.name) orelse return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(builder, dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(builder, field_access.base);
                    },
                }
            },
            .child_navigation => |child_nav| {
                switch (child_nav.parent) {
                    .variable => |variable| {
                        const dep_var_id = (self.variables.get(variable.name)) orelse
                            return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(builder, dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(builder, child_nav.parent);
                    },
                }
            },
            .descendant_navigation => |desc_nav| {
                switch (desc_nav.parent) {
                    .variable => |variable| {
                        const dep_var_id = self.variables.get(variable.name) orelse
                            return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(builder, dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(builder, desc_nav.parent);
                    },
                }
            },
            .node_selector => {
                try self.ensureRootNavigated(builder);
            },
            .parenthesized => |parenthesized| {
                try self.ensureExpressionDependencies(builder, parenthesized.*);
            },
            else => @panic("Non-navigation expression as dependency"),
        }
    }

    fn compileAsNavigation(
        self: *Compiler,
        builder: *InstructionBuilder,
        expr: ast.Expression,
    ) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                try self.compileVariableSelector(builder, variable);
            },
            .node_selector => |node_selector| {
                try self.compileNodeSelector(builder, node_selector);
            },
            .field_access => |field_access| {
                try self.compileFieldAccess(builder, field_access);
            },
            .child_navigation => |nested_child_nav| {
                try self.compileChildNavigation(builder, nested_child_nav);
            },
            .descendant_navigation => |desc_nav| {
                try self.compileDescendantNavigation(builder, desc_nav);
            },
            .parenthesized => |parenthesized| {
                try self.compileAsNavigation(builder, parenthesized.*);
            },
            else => @panic("value expression used in navigation position"),
        }
    }

    fn compileFieldAccess(self: *Compiler, builder: *InstructionBuilder, field_access: *ast.FieldAccess) CompilerError!void {
        try self.compileAsNavigation(builder, field_access.base);
        const field_id = self.language.fieldIdForName(field_access.field);
        try builder.emit(.{ .trv = .{ .field = field_id } });
    }

    fn compileChildNavigation(self: *Compiler, builder: *InstructionBuilder, child_nav: *ast.ChildNavigation) CompilerError!void {
        try self.compileAsNavigation(builder, child_nav.parent);
        try builder.emit(.{ .trv = .{ .child = {} } });

        // FIXME: Why can't I do self.compileAsNavigation(builder, child_nav.child)?
        // see compileNodeSelector
        switch (child_nav.child) {
            .node_selector => |node_selector| {
                const kind_id = self.language.idForNodeKind(node_selector.node_type, true);
                try builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .kind },
                    .b = .{ .literal = .{ .kind_id = kind_id } },
                } });
                try builder.emit(.{ .halt = .{ .condition = .not_relates } });
            },
            else => unreachable,
        }
    }

    fn compileDescendantNavigation(self: *Compiler, builder: *InstructionBuilder, desc_nav: *ast.DescendantNavigation) CompilerError!void {
        try self.compileAsNavigation(builder, desc_nav.parent);

        try builder.emit(.{ .trv = .{ .descendant = {} } });

        // FIXME: Why can't I do self.compileAsNavigation(builder, desc_nav.child)?
        // see compileNodeSelector
        switch (desc_nav.descendant) {
            .node_selector => |node_selector| {
                const kind_id = self.language.idForNodeKind(node_selector.node_type, true);
                try builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .kind },
                    .b = .{ .literal = .{ .kind_id = kind_id } },
                } });
                try builder.emit(.{ .halt = .{ .condition = .not_relates } });
            },
            else => {},
        }
    }

    fn compileVariableSelector(self: *Compiler, builder: *InstructionBuilder, variable: ast.Variable) CompilerError!void {
        if (self.variables.get(variable.name)) |parent_var_id| {
            try builder.emit(.{ .trv = .{ .variable_id = parent_var_id } });
        } else {
            return error.InvalidVariableReference;
        }
    }

    fn compileNodeSelector(self: *Compiler, builder: *InstructionBuilder, node_selector: ast.NodeSelector) !void {
        const kind_id = self.language.idForNodeKind(node_selector.node_type, true);

        // FIXME: This can't be right
        // yeah the root problem is the implicit root child traversal.
        // no pun intended.
        // any implicit root traversal with the top level selector is bound to
        // run into this problem and is the same reason why we can't do the
        // compileAsNavigation mentioned in the other comments
        try builder.emit(.{ .trv = .{ .child = {} } });
        try builder.emit(.{ .rel = .{
            .relation = .equals,
            .a = .{ .node = .kind },
            .b = .{ .literal = .{ .kind_id = kind_id } },
        } });
        try builder.emit(.{ .halt = .{ .condition = .not_relates } });
    }

    fn compileWhereClause(self: *Compiler, builder: *InstructionBuilder, where_clause: ast.WhereClause) CompilerError!void {
        const success_label = builder.createLabel();
        const failure_label = builder.createLabel();
        try self.compilePredicate(builder, where_clause.predicate, success_label, failure_label);

        try builder.markLabel(failure_label);
        try builder.emit(.{ .halt = .{ .condition = .always } });

        try builder.markLabel(success_label);
    }

    fn compilePredicate(
        self: *Compiler,
        builder: *InstructionBuilder,
        predicate: ast.Predicate,
        success_label: LabelId,
        failure_label: LabelId,
    ) CompilerError!void {
        switch (predicate) {
            .comparison => |comparison| {
                try self.compileComparison(builder, comparison, success_label, failure_label);
            },
            .is_null => |is_null| {
                try self.compileIsNull(builder, is_null, success_label);
            },
            .logical_and => |logical_and| {
                const check_right_label = builder.createLabel();

                try self.compilePredicate(builder, logical_and.left, check_right_label, failure_label);

                try builder.markLabel(check_right_label);
                try self.compilePredicate(builder, logical_and.right, success_label, failure_label);
            },
            .logical_or => |logical_or| {
                const fallback_label = builder.createLabel();

                try self.compilePredicate(builder, logical_or.left, success_label, fallback_label);

                try builder.markLabel(fallback_label);
                try self.compilePredicate(builder, logical_or.right, success_label, failure_label);

                try builder.emitJump(success_label, .always);
            },
            .logical_not => |logical_not| {
                // special case for quantifiers where we have to change probe mode.
                // I feel like we shouldn't have allowed this in the first place
                if (logical_not.*.predicate == .quantified) {
                    try self.compileQuantified(builder, logical_not.*.predicate.quantified, success_label, true);
                } else {
                    try self.compilePredicate(builder, logical_not.*.predicate, failure_label, success_label);
                }
            },
            .quantified => |quantified| {
                try self.compileQuantified(builder, quantified, success_label, false);
            },
            .parenthesized => |parenthesized| {
                try self.compilePredicate(builder, parenthesized.*, success_label, failure_label);
            },
        }
    }

    fn compileQuantified(
        self: *Compiler,
        builder: *InstructionBuilder,
        quantified: ast.QuantifiedExpression,
        outer_success_label: LabelId,
        negated: bool,
    ) CompilerError!void {
        const body_negated = quantified.quantifier == .all;
        const probe_negated = negated != body_negated;

        const probe_success_label = builder.createLabel();

        const bindings_snapshot = self.bindings.items.len;
        const var_id = try self.variables.getOrPut(quantified.variable.name);

        try self.ensureExpressionDependencies(builder, quantified.source);

        const probe_mode: runtime.ProbeMode = if (probe_negated) .nexists else .exists;
        try builder.emitProbe(probe_mode, probe_success_label);

        try self.compileAsNavigation(builder, quantified.source);
        try builder.emit(.{ .asn = .{
            .variable_id = var_id,
            .source = .{ .node = .this },
        } });

        try self.bindings.append(self.allocator, .{
            .variable_id = var_id,
            .expression = quantified.source,
            .emitted = true,
        });

        const inner_success_label = builder.createLabel();
        const inner_failure_label = builder.createLabel();
        if (body_negated) {
            try self.compilePredicate(builder, quantified.predicate.*, inner_failure_label, inner_success_label);
        } else {
            try self.compilePredicate(builder, quantified.predicate.*, inner_success_label, inner_failure_label);
        }

        try builder.markLabel(inner_success_label);
        try builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });

        try builder.markLabel(inner_failure_label);
        try builder.emit(.{ .halt = .{ .condition = .always } });

        try builder.markLabel(probe_success_label);
        try builder.emitJump(outer_success_label, .always);

        self.bindings.shrinkRetainingCapacity(bindings_snapshot);
    }

    fn compileIsNull(
        self: *Compiler,
        builder: *InstructionBuilder,
        is_null: ast.IsNullPredicate,
        success_label: LabelId,
    ) CompilerError!void {
        const probe_success_label = builder.createLabel();

        try self.ensureExpressionDependencies(builder, is_null.expression);

        const probe_mode: runtime.ProbeMode = if (is_null.negated) .exists else .nexists;
        try builder.emitProbe(probe_mode, probe_success_label);

        try self.compileAsNavigation(builder, is_null.expression);
        try builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
        try builder.emit(.{ .halt = .{ .condition = .always } });

        try builder.markLabel(probe_success_label);
        try builder.emitJump(success_label, .always);
    }

    fn compileComparison(
        self: *Compiler,
        builder: *InstructionBuilder,
        comparison: ast.Comparison,
        // there's definitely a simplification here
        success_label: LabelId,
        failure_label: LabelId,
    ) CompilerError!void {
        if (comparison.right == .string_literal) {
            if (try self.ensureExpressionAsVariable(builder, comparison.left)) |var_id| {
                const owned_str = try self.addString(comparison.right.string_literal);

                try builder.emit(.{ .trv = .{ .variable_id = var_id } });
                try builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .string = owned_str } },
                } });

                try builder.emitJump(success_label, .relates);
                try builder.emitJump(failure_label, .always);
                return;
            }
        }

        if (comparison.right == .regex_literal) {
            if (try self.ensureExpressionAsVariable(builder, comparison.left)) |var_id| {
                try builder.emit(.{ .trv = .{ .variable_id = var_id } });

                const regex = try pcre2.Regex.compile(comparison.right.regex_literal);
                const regex_index = try self.addRegex(regex);

                try builder.emit(.{ .rel = .{
                    .relation = .like,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .regex = self.regexes.items[regex_index] } },
                } });

                switch (comparison.operator) {
                    .regex_match => {
                        try builder.emitJump(success_label, .relates);
                        try builder.emitJump(failure_label, .always);
                    },
                    .regex_not_match => {
                        try builder.emitJump(failure_label, .relates);
                        try builder.emitJump(success_label, .always);
                    },
                    else => unreachable,
                }
                return;
            }
        }

        const left_source = try self.compileAsValue(builder, comparison.left);
        const right_source = try self.compileAsValue(builder, comparison.right);

        const relation: Relation = switch (comparison.operator) {
            .eq => .equals,
            .ne => {
                try builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = left_source,
                    .b = right_source,
                } });
                try builder.emitJump(failure_label, .relates);
                try builder.emitJump(success_label, .always);
                return;
            },
            .regex_match => .like,
            .regex_not_match => {
                try builder.emit(.{ .rel = .{
                    .relation = .like,
                    .a = left_source,
                    .b = right_source,
                } });
                try builder.emitJump(failure_label, .relates);
                try builder.emitJump(success_label, .always);
                return;
            },
            .gt => .gt,
            .lt => .lt,
            .gte, .lte => @panic("gte/lte not yet implemented"),
        };

        try builder.emit(.{ .rel = .{
            .relation = relation,
            .a = left_source,
            .b = right_source,
        } });

        try builder.emitJump(success_label, .relates);
        try builder.emitJump(failure_label, .always);
    }

    fn ensureExpressionAsVariable(
        self: *Compiler,
        builder: *InstructionBuilder,
        expr: ast.Expression,
    ) CompilerError!?VariableId {
        return switch (expr) {
            .variable => |v| blk: {
                const var_id = self.variables.get(v.name) orelse return error.InvalidVariableReference;
                try self.ensureVariableNavigated(builder, var_id);
                break :blk var_id;
            },
            .field_access, .child_navigation, .descendant_navigation, .node_selector => try self.liftNavigation(builder, expr),
            .parenthesized => |p| try self.ensureExpressionAsVariable(builder, p.*),
            // TODO: we should be able to support all expressions as variables
            else => @panic("TODO"),
        };
    }

    fn liftNavigation(self: *Compiler, builder: *InstructionBuilder, expr: ast.Expression) CompilerError!VariableId {
        const anon_id = self.variables.allocateAnonymous();
        try self.bindings.append(self.allocator, .{
            .variable_id = anon_id,
            .expression = expr,
            .emitted = false,
        });
        try self.ensureVariableNavigated(builder, anon_id);
        return anon_id;
    }

    fn compileAsValue(self: *Compiler, builder: *InstructionBuilder, expr: ast.Expression) CompilerError!runtime.ValueSource {
        return switch (expr) {
            .variable => |variable| {
                if (self.variables.get(variable.name)) |var_id| {
                    try self.ensureVariableNavigated(builder, var_id);
                    return runtime.ValueSource{ .variable_id = var_id };
                } else {
                    return error.InvalidVariableReference;
                }
            },
            .string_literal => |str| {
                const owned_str = try self.addString(str);
                return runtime.ValueSource{
                    .literal = .{ .string = owned_str },
                };
            },
            .number_literal => |number| runtime.ValueSource{
                .literal = .{ .uint = number },
            },
            .null_literal => runtime.ValueSource{
                .literal = .{ .nothing = {} },
            },
            .regex_literal => |pattern| {
                const regex = try pcre2.Regex.compile(pattern);
                const regex_index = try self.addRegex(regex);
                return runtime.ValueSource{
                    .literal = .{ .regex = self.regexes.items[regex_index] },
                };
            },
            .field_access, .child_navigation, .descendant_navigation, .node_selector => blk: {
                const anon_id = try self.liftNavigation(builder, expr);
                break :blk runtime.ValueSource{ .variable_id = anon_id };
            },
            .parenthesized => |p| try self.compileAsValue(builder, p.*),
            .object_literal => |obj| try self.compileRecordExpression(builder, obj),
            .array_literal => |arr| try self.compileListExpression(builder, arr.elements),
            .tuple_literal => |tup| try self.compileListExpression(builder, tup.elements),
            .function_call, .subquery => @panic("TODO"),
        };
    }

    fn compileRecordExpression(self: *Compiler, builder: *InstructionBuilder, obj: ast.ObjectLiteral) CompilerError!runtime.ValueSource {
        const FieldSource = struct { key: []const u8, source: runtime.ValueSource };
        var sources = try self.allocator.alloc(FieldSource, obj.fields.len);
        defer self.allocator.free(sources);

        for (obj.fields, 0..) |field, i| {
            switch (field) {
                .variable => |variable| {
                    const var_id = self.variables.get(variable.name) orelse
                        return error.InvalidVariableReference;
                    try self.ensureVariableNavigated(builder, var_id);
                    sources[i] = .{
                        .key = try self.addString(variable.name),
                        .source = .{ .variable_id = var_id },
                    };
                },
                .key_value => |kv| {
                    const source = try self.compileAsValue(builder, kv.value);
                    sources[i] = .{
                        .key = try self.addString(kv.key),
                        .source = source,
                    };
                },
            }
        }

        try builder.emit(.{ .begin_build = .record });
        for (sources) |fs| {
            try builder.emit(.{ .push_build = .{ .source = fs.source, .name = fs.key } });
        }
        const tmp = self.variables.allocateAnonymous();
        try builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }

    fn compileListExpression(self: *Compiler, builder: *InstructionBuilder, elements: []const ast.Expression) CompilerError!runtime.ValueSource {
        const sources = try self.allocator.alloc(runtime.ValueSource, elements.len);
        defer self.allocator.free(sources);

        for (elements, 0..) |elem, i| {
            sources[i] = try self.compileAsValue(builder, elem);
        }

        try builder.emit(.{ .begin_build = .list });
        for (sources) |s| {
            try builder.emit(.{ .push_build = .{ .source = s, .name = null } });
        }
        const tmp = self.variables.allocateAnonymous();
        try builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }

    fn compileSelectClause(self: *Compiler, builder: *InstructionBuilder, select_clause: ast.SelectClause) !void {
        const vs = try self.compileAsValue(builder, select_clause.projection);
        try builder.emit(.{ .yield = .{ .source = vs } });
    }
};
