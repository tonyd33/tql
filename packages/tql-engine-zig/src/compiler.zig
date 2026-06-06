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
const pcre2 = @import("regex.zig");

pub const VariableTable = @import("compiler/variable_table.zig").VariableTable;
pub const InstructionBuilder = @import("compiler/instruction_builder.zig").InstructionBuilder;
const CompilerError = @import("compiler/types.zig").CompilerError;

const LabelId = u32;

const BindingMetadata = struct {
    variable_id: VariableId,
    // HACK: root doesn't have an expression
    expression: ?ast.Expression,
    emitted: bool = false,
};

const ROOT_NAME = "root";

pub const Compiler = struct {
    language: *ts.Language,

    allocator: Allocator,
    instruction_builder: InstructionBuilder,
    variable_table: VariableTable,
    binding_metadata: std.ArrayList(BindingMetadata),

    regexes: std.ArrayList(pcre2.Regex),
    strings: std.ArrayList([]const u8),

    // FIXME: we're supposed to detect the language
    pub fn init(allocator: Allocator, language: *ts.Language) Compiler {
        const strings = std.ArrayList([]const u8).empty;
        const regexes = std.ArrayList(pcre2.Regex).empty;
        const bindings = std.ArrayList(BindingMetadata).empty;
        const variables = VariableTable.init(allocator);
        const instruction_builder = InstructionBuilder.init(allocator);
        return .{
            .allocator = allocator,
            .variable_table = variables,
            .language = language,
            .binding_metadata = bindings,
            .regexes = regexes,
            .strings = strings,
            .instruction_builder = instruction_builder,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instruction_builder.deinit();

        self.variable_table.deinit();

        self.binding_metadata.deinit(self.allocator);

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
        const root_id = try self.variable_table.getOrPut(ROOT_NAME);
        try self.binding_metadata.append(self.allocator, .{
            .variable_id = root_id,
            .expression = null,
            .emitted = true,
        });
        try self.instruction_builder.emit(.{ .asn = .{
            .variable_id = root_id,
            .source = .{ .node = .this },
        } });

        for (source.items) |item| {
            switch (item) {
                // TODO: turn into proper function
                .query => |query| try self.compileQueryBody(query.body),
                .query_body => |query_body| try self.compileQueryBody(query_body),
                else => {
                    @panic("Not implemented");
                },
            }
        }

        var variable_iterator = self.variable_table.map.iterator();
        var variable_map = std.hash_map.AutoHashMap(runtime.VariableId, []const u8).init(allocator);
        while (variable_iterator.next()) |entry| {
            const slice = try self.addString(entry.key_ptr.*);
            try variable_map.put(entry.value_ptr.*, slice);
        }

        const instructions = try self.instruction_builder.patch(allocator);
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

    fn compileQueryBody(self: *Compiler, body: ast.QueryBody) !void {
        if (body.with_clause) |with_clause| {
            try self.compileWithClause(with_clause);
        }

        if (body.where_clause) |where_clause| {
            try self.compileWhereClause(where_clause);
        }

        try self.compileSelectClause(body.select_clause);
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
    }

    fn compileWithClause(self: *Compiler, with_clause: ast.WithClause) CompilerError!void {
        for (with_clause.bindings) |binding| {
            try self.compileBinding(binding);
        }
    }

    fn compileBinding(self: *Compiler, binding: ast.Binding) CompilerError!void {
        const var_id = try self.variable_table.getOrPut(binding.variable.name);

        try self.binding_metadata.append(self.allocator, .{
            .variable_id = var_id,
            .expression = binding.expression,
            .emitted = false,
        });
    }

    fn ensureRootNavigated(self: *Compiler) CompilerError!void {
        const root_id = self.variable_table.get(ROOT_NAME) orelse return error.InvalidVariableReference;
        try self.instruction_builder.emit(.{ .trv = .{ .variable_id = root_id } });
    }

    fn ensureVariableNavigated(self: *Compiler, var_id: VariableId) CompilerError!void {
        for (self.binding_metadata.items) |*binding| {
            if (binding.variable_id == var_id) {
                if (binding.emitted) return;

                if (binding.expression) |expression| {
                    try self.ensureExpressionDependencies(expression);
                    try self.navigate(expression);
                }
                try self.instruction_builder.emit(.{ .asn = .{
                    .variable_id = var_id,
                    .source = .{ .node = .this },
                } });
                binding.emitted = true;
                return;
            }
        }
        return error.InvalidVariableReference;
    }

    fn ensureExpressionDependencies(self: *Compiler, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                const dep_var_id = self.variable_table.get(variable.name) orelse return error.InvalidVariableReference;
                try self.ensureVariableNavigated(dep_var_id);
            },
            .field_access => |field_access| {
                switch (field_access.base) {
                    .variable => |variable| {
                        const dep_var_id = self.variable_table.get(variable.name) orelse return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(field_access.base);
                    },
                }
            },
            .child_navigation => |child_nav| {
                switch (child_nav.parent) {
                    .variable => |variable| {
                        const dep_var_id = (self.variable_table.get(variable.name)) orelse
                            return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(child_nav.parent);
                    },
                }
            },
            .descendant_navigation => |desc_nav| {
                switch (desc_nav.parent) {
                    .variable => |variable| {
                        const dep_var_id = self.variable_table.get(variable.name) orelse
                            return error.InvalidVariableReference;
                        try self.ensureVariableNavigated(dep_var_id);
                    },
                    else => {
                        try self.ensureExpressionDependencies(desc_nav.parent);
                    },
                }
            },
            .node_selector => {
                try self.ensureExpressionDependencies(expr);
            },
            .parenthesized => |parenthesized| {
                try self.ensureExpressionDependencies(parenthesized.*);
            },
            else => @panic("Non-navigation expression as dependency"),
        }
    }

    fn navigate(
        self: *Compiler,
        expr: ast.Expression,
    ) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                try self.navigateVariable(variable);
            },
            .node_selector => |node_selector| {
                try self.navigateNodeSelector(node_selector);
            },
            .field_access => |field_access| {
                try self.navigateFieldAccess(field_access);
            },
            .child_navigation => |nested_child_nav| {
                try self.navigateChild(nested_child_nav);
            },
            .descendant_navigation => |desc_nav| {
                try self.navigateDescendant(desc_nav);
            },
            .parenthesized => |parenthesized| {
                try self.navigate(parenthesized.*);
            },
            else => @panic("value expression used in navigation position"),
        }
    }

    fn navigateFieldAccess(self: *Compiler, field_access: *ast.FieldAccess) CompilerError!void {
        try self.navigate(field_access.base);
        const field_id = self.language.fieldIdForName(field_access.field);
        try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
    }

    fn navigateChild(self: *Compiler, child_nav: *ast.ChildNavigation) CompilerError!void {
        try self.navigate(child_nav.parent);
        try self.instruction_builder.emit(.{ .trv = .{ .child = {} } });
        try self.navigate(child_nav.child);
    }

    fn navigateDescendant(self: *Compiler, desc_nav: *ast.DescendantNavigation) CompilerError!void {
        try self.navigate(desc_nav.parent);
        try self.instruction_builder.emit(.{ .trv = .{ .descendant = {} } });
        try self.navigate(desc_nav.descendant);
    }

    fn navigateVariable(self: *Compiler, variable: ast.Variable) CompilerError!void {
        if (self.variable_table.get(variable.name)) |parent_var_id| {
            try self.instruction_builder.emit(.{ .trv = .{ .variable_id = parent_var_id } });
        } else {
            return error.InvalidVariableReference;
        }
    }

    fn navigateNodeSelector(self: *Compiler, node_selector: ast.NodeSelector) !void {
        const kind_id = self.language.idForNodeKind(node_selector.node_type, true);

        try self.instruction_builder.emit(.{ .rel = .{
            .relation = .equals,
            .a = .{ .node = .kind },
            .b = .{ .literal = .{ .kind_id = kind_id } },
        } });
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .not_relates } });
    }

    fn compileWhereClause(self: *Compiler, where_clause: ast.WhereClause) CompilerError!void {
        const success_label = self.instruction_builder.createLabel();
        const failure_label = self.instruction_builder.createLabel();
        try self.compilePredicate(where_clause.predicate, success_label, failure_label);

        try self.instruction_builder.markLabel(failure_label);
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

        try self.instruction_builder.markLabel(success_label);
    }

    fn compilePredicate(
        self: *Compiler,
        predicate: ast.Predicate,
        success_label: LabelId,
        failure_label: LabelId,
    ) CompilerError!void {
        switch (predicate) {
            .comparison => |comparison| {
                try self.compileComparison(comparison, success_label, failure_label);
            },
            .is_null => |is_null| {
                try self.compileIsNull(is_null, success_label);
            },
            .logical_and => |logical_and| {
                const check_right_label = self.instruction_builder.createLabel();

                try self.compilePredicate(logical_and.left, check_right_label, failure_label);

                try self.instruction_builder.markLabel(check_right_label);
                try self.compilePredicate(logical_and.right, success_label, failure_label);
            },
            .logical_or => |logical_or| {
                const fallback_label = self.instruction_builder.createLabel();

                try self.compilePredicate(logical_or.left, success_label, fallback_label);

                try self.instruction_builder.markLabel(fallback_label);
                try self.compilePredicate(logical_or.right, success_label, failure_label);

                try self.instruction_builder.emitJump(success_label, .always);
            },
            .logical_not => |logical_not| {
                // special case for quantifiers where we have to change probe mode.
                // I feel like we shouldn't have allowed this in the first place
                if (logical_not.*.predicate == .quantified) {
                    try self.compileQuantified(logical_not.*.predicate.quantified, success_label, true);
                } else {
                    try self.compilePredicate(logical_not.*.predicate, failure_label, success_label);
                }
            },
            .quantified => |quantified| {
                try self.compileQuantified(quantified, success_label, false);
            },
            .parenthesized => |parenthesized| {
                try self.compilePredicate(parenthesized.*, success_label, failure_label);
            },
        }
    }

    fn compileQuantified(
        self: *Compiler,
        quantified: ast.QuantifiedExpression,
        outer_success_label: LabelId,
        negated: bool,
    ) CompilerError!void {
        const body_negated = quantified.quantifier == .all;
        const probe_negated = negated != body_negated;

        const probe_resume_label = self.instruction_builder.createLabel();

        const bindings_snapshot = self.binding_metadata.items.len;
        const var_id = try self.variable_table.getOrPut(quantified.variable.name);

        try self.ensureExpressionDependencies(quantified.source);

        const probe_data: runtime.ProbeData = if (probe_negated) .nexists else .exists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        try self.navigate(quantified.source);
        try self.instruction_builder.emit(.{ .asn = .{
            .variable_id = var_id,
            .source = .{ .node = .this },
        } });

        try self.binding_metadata.append(self.allocator, .{
            .variable_id = var_id,
            .expression = quantified.source,
            .emitted = true,
        });

        const inner_success_label = self.instruction_builder.createLabel();
        const inner_failure_label = self.instruction_builder.createLabel();
        if (body_negated) {
            try self.compilePredicate(quantified.predicate.*, inner_failure_label, inner_success_label);
        } else {
            try self.compilePredicate(quantified.predicate.*, inner_success_label, inner_failure_label);
        }

        try self.instruction_builder.markLabel(inner_success_label);
        try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });

        try self.instruction_builder.markLabel(inner_failure_label);
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

        try self.instruction_builder.markLabel(probe_resume_label);
        try self.instruction_builder.emitJump(outer_success_label, .always);

        self.binding_metadata.shrinkRetainingCapacity(bindings_snapshot);
    }

    fn compileIsNull(
        self: *Compiler,
        is_null: ast.IsNullPredicate,
        resume_label: LabelId,
    ) CompilerError!void {
        const probe_resume_label = self.instruction_builder.createLabel();

        try self.ensureExpressionDependencies(is_null.expression);

        const probe_data: runtime.ProbeData = if (is_null.negated) .exists else .nexists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        try self.navigate(is_null.expression);
        try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

        try self.instruction_builder.markLabel(probe_resume_label);
        try self.instruction_builder.emitJump(resume_label, .always);
    }

    fn compileComparison(
        self: *Compiler,
        comparison: ast.Comparison,
        // there's definitely a simplification here
        success_label: LabelId,
        failure_label: LabelId,
    ) CompilerError!void {
        if (comparison.right == .string_literal) {
            if (try self.ensureExpressionAsVariable(comparison.left)) |var_id| {
                const owned_str = try self.addString(comparison.right.string_literal);

                try self.instruction_builder.emit(.{ .trv = .{ .variable_id = var_id } });
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .string = owned_str } },
                } });

                try self.instruction_builder.emitJump(success_label, .relates);
                try self.instruction_builder.emitJump(failure_label, .always);
                return;
            }
        }

        if (comparison.right == .regex_literal) {
            if (try self.ensureExpressionAsVariable(comparison.left)) |var_id| {
                try self.instruction_builder.emit(.{ .trv = .{ .variable_id = var_id } });

                const regex = try pcre2.Regex.compile(comparison.right.regex_literal);
                const regex_index = try self.addRegex(regex);

                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .like,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .regex = self.regexes.items[regex_index] } },
                } });

                switch (comparison.operator) {
                    .regex_match => {
                        try self.instruction_builder.emitJump(success_label, .relates);
                        try self.instruction_builder.emitJump(failure_label, .always);
                    },
                    .regex_not_match => {
                        try self.instruction_builder.emitJump(failure_label, .relates);
                        try self.instruction_builder.emitJump(success_label, .always);
                    },
                    else => unreachable,
                }
                return;
            }
        }

        const left_source = try self.compileAsValue(comparison.left);
        const right_source = try self.compileAsValue(comparison.right);

        const relation: Relation = switch (comparison.operator) {
            .eq => .equals,
            .ne => {
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = left_source,
                    .b = right_source,
                } });
                try self.instruction_builder.emitJump(failure_label, .relates);
                try self.instruction_builder.emitJump(success_label, .always);
                return;
            },
            .regex_match => .like,
            .regex_not_match => {
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .like,
                    .a = left_source,
                    .b = right_source,
                } });
                try self.instruction_builder.emitJump(failure_label, .relates);
                try self.instruction_builder.emitJump(success_label, .always);
                return;
            },
            .gt => .gt,
            .lt => .lt,
            .gte, .lte => @panic("gte/lte not yet implemented"),
        };

        try self.instruction_builder.emit(.{ .rel = .{
            .relation = relation,
            .a = left_source,
            .b = right_source,
        } });

        try self.instruction_builder.emitJump(success_label, .relates);
        try self.instruction_builder.emitJump(failure_label, .always);
    }

    fn ensureExpressionAsVariable(
        self: *Compiler,
        expr: ast.Expression,
    ) CompilerError!?VariableId {
        return switch (expr) {
            .variable => |v| blk: {
                const var_id = self.variable_table.get(v.name) orelse return error.InvalidVariableReference;
                try self.ensureVariableNavigated(var_id);
                break :blk var_id;
            },
            .field_access, .child_navigation, .descendant_navigation, .node_selector => try self.liftNavigation(expr),
            .parenthesized => |p| try self.ensureExpressionAsVariable(p.*),
            // TODO: we should be able to support all expressions as variables
            else => @panic("TODO"),
        };
    }

    fn liftNavigation(self: *Compiler, expr: ast.Expression) CompilerError!VariableId {
        const anon_id = self.variable_table.allocateAnonymous();
        try self.binding_metadata.append(self.allocator, .{
            .variable_id = anon_id,
            .expression = expr,
            .emitted = false,
        });
        try self.ensureVariableNavigated(anon_id);
        return anon_id;
    }

    fn compileAsValue(self: *Compiler, expr: ast.Expression) CompilerError!runtime.ValueSource {
        return switch (expr) {
            .variable => |variable| {
                if (self.variable_table.get(variable.name)) |var_id| {
                    try self.ensureVariableNavigated(var_id);
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
            .field_access,
            .child_navigation,
            .descendant_navigation,
            .node_selector,
            => blk: {
                const anon_id = try self.liftNavigation(expr);
                break :blk runtime.ValueSource{ .variable_id = anon_id };
            },
            .parenthesized => |p| try self.compileAsValue(p.*),
            .object_literal => |obj| try self.compileRecordExpression(obj),
            .array_literal => |arr| try self.compileListExpression(arr.elements),
            .tuple_literal => |tup| try self.compileListExpression(tup.elements),
            .subquery => |sq| try self.compileSubquery(sq),
            .function_call => @panic("TODO"),
        };
    }

    fn compileRecordExpression(self: *Compiler, obj: ast.ObjectLiteral) CompilerError!runtime.ValueSource {
        const FieldSource = struct { key: []const u8, source: runtime.ValueSource };
        var sources = try self.allocator.alloc(FieldSource, obj.fields.len);
        defer self.allocator.free(sources);

        for (obj.fields, 0..) |field, i| {
            switch (field) {
                .variable => |variable| {
                    const var_id = self.variable_table.get(variable.name) orelse
                        return error.InvalidVariableReference;
                    try self.ensureVariableNavigated(var_id);
                    sources[i] = .{
                        .key = try self.addString(variable.name),
                        .source = .{ .variable_id = var_id },
                    };
                },
                .key_value => |kv| {
                    const source = try self.compileAsValue(kv.value);
                    sources[i] = .{
                        .key = try self.addString(kv.key),
                        .source = source,
                    };
                },
            }
        }

        try self.instruction_builder.emit(.{ .begin_build = .record });
        for (sources) |fs| {
            try self.instruction_builder.emit(.{ .push_build = .{ .source = fs.source, .name = fs.key } });
        }
        const tmp = self.variable_table.allocateAnonymous();
        try self.instruction_builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }

    fn compileListExpression(self: *Compiler, elements: []const ast.Expression) CompilerError!runtime.ValueSource {
        const sources = try self.allocator.alloc(runtime.ValueSource, elements.len);
        defer self.allocator.free(sources);

        for (elements, 0..) |elem, i| {
            sources[i] = try self.compileAsValue(elem);
        }

        try self.instruction_builder.emit(.{ .begin_build = .list });
        for (sources) |s| {
            try self.instruction_builder.emit(.{ .push_build = .{ .source = s, .name = null } });
        }
        const tmp = self.variable_table.allocateAnonymous();
        try self.instruction_builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }

    fn compileSubquery(self: *Compiler, subquery: *ast.QueryBody) CompilerError!runtime.ValueSource {
        const resume_label = self.instruction_builder.createLabel();
        const anon_variable = self.variable_table.allocateAnonymous();

        try self.instruction_builder.emitProbe(.{
            .aggregate = .{
                .variable = anon_variable,
                .kind = .list,
            },
        }, resume_label);
        try self.compileQueryBody(subquery.*);

        try self.instruction_builder.markLabel(resume_label);

        return .{ .variable_id = anon_variable };
    }

    fn compileSelectClause(self: *Compiler, select_clause: ast.SelectClause) !void {
        const vs = try self.compileAsValue(select_clause.projection);
        try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
    }
};
