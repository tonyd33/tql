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

const variable_table = @import("compiler/variable_table.zig");
pub const VariableTable = variable_table.VariableTable;
const ScopeStack = variable_table.ScopeStack;
pub const InstructionBuilder = @import("compiler/instruction_builder.zig").InstructionBuilder;
const CompilerError = @import("compiler/types.zig").CompilerError;

const LabelId = u32;

const BindingMetadata = struct {
    variable_id: VariableId,
    /// How to navigate to this variable, if applicable.
    navigation: union(enum) {
        // IMPROVE: maybe we want a first-class separation of navigable expressions?
        /// To navigate to this variable, evaluate the following expression.
        expression: ast.Expression,
        /// To navigate to this variable, run the subquery body and bind the
        /// projection of each yielded fan-out path into this variable.
        unnest_subquery: *ast.QueryBody,
        /// This variable does not need evaluation.
        none,
    },
    emitted: bool = false,
};

const ROOT_NAME = "root";

pub const Compiler = struct {
    language: *ts.Language,

    allocator: Allocator,
    instruction_builder: InstructionBuilder,
    scope_stack: ScopeStack,
    binding_metadata: std.ArrayList(BindingMetadata),

    regexes: std.ArrayList(pcre2.Regex),
    strings: std.ArrayList([]const u8),

    // FIXME: we're supposed to detect the language
    pub fn init(allocator: Allocator, language: *ts.Language) Compiler {
        const strings = std.ArrayList([]const u8).empty;
        const regexes = std.ArrayList(pcre2.Regex).empty;
        const bindings = std.ArrayList(BindingMetadata).empty;
        const scope_stack = ScopeStack.init(allocator);
        const instruction_builder = InstructionBuilder.init(allocator);
        return .{
            .allocator = allocator,
            .scope_stack = scope_stack,
            .language = language,
            .binding_metadata = bindings,
            .regexes = regexes,
            .strings = strings,
            .instruction_builder = instruction_builder,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instruction_builder.deinit();

        self.scope_stack.deinit();

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

    // START environment manipulation primitives

    fn bindCursorTo(self: *Compiler, var_id: VariableId) CompilerError!void {
        try self.instruction_builder.emit(.{ .asn = .{
            .variable_id = var_id,
            .source = .{ .node = .this },
        } });
    }

    fn bindValueTo(self: *Compiler, var_id: VariableId, source: runtime.ValueSource) CompilerError!void {
        try self.instruction_builder.emit(.{ .asn = .{
            .variable_id = var_id,
            .source = source,
        } });
    }

    // END environment manipulation primitives

    // START cursor manipulation primitives

    fn navigateToVariable(self: *Compiler, var_id: VariableId) CompilerError!void {
        try self.forceBoundEvaluation(var_id);
        try self.instruction_builder.emit(.{ .trv = .{ .variable_id = var_id } });
    }

    fn navigateTo(
        self: *Compiler,
        expr: ast.Expression,
    ) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                const var_id = self.scope_stack.get(variable.name) orelse return error.InvalidVariableReference;
                try self.navigateToVariable(var_id);
            },
            .node_selector => |node_selector| {
                const kind_id = self.language.idForNodeKind(node_selector.node_type, true);
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .kind },
                    .b = .{ .literal = .{ .kind_id = kind_id } },
                } });
                try self.instruction_builder.emit(.{ .halt = .{ .condition = .not_relates } });
            },
            .field_access => |field_access| {
                try self.navigateTo(field_access.base);
                const field_id = self.language.fieldIdForName(field_access.field);
                try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
            },
            .child_navigation => |child_nav| {
                try self.navigateTo(child_nav.parent);
                try self.instruction_builder.emit(.{ .trv = .{ .child = {} } });
                try self.navigateTo(child_nav.child);
            },
            .descendant_navigation => |desc_nav| {
                try self.navigateTo(desc_nav.parent);
                try self.instruction_builder.emit(.{ .trv = .{ .descendant = {} } });
                try self.navigateTo(desc_nav.descendant);
            },
            .parenthesized => |parenthesized| {
                try self.navigateTo(parenthesized.*);
            },
            else => @panic("value expression used in navigation position"),
        }
    }

    // END cursor manipulation primitives

    pub fn compile(self: *Compiler, allocator: std.mem.Allocator, source: ast.SourceFile) CompilerError!ProgramImage {
        try self.scope_stack.enterScope();
        const root_id = try self.scope_stack.getOrPut(ROOT_NAME);
        try self.binding_metadata.append(self.allocator, .{
            .variable_id = root_id,
            .navigation = .none,
            .emitted = true,
        });
        try self.bindCursorTo(root_id);

        for (source.items) |item| {
            switch (item) {
                // TODO: turn into proper function
                .query => |query| {
                    if (query.body.with_clause) |wc| try self.compileWithClause(wc);
                    if (query.body.where_clause) |wc| try self.compileWhereClause(wc);
                    try self.compileSelectClause(query.body.select_clause);
                    try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
                },
                .query_body => |query_body| {
                    if (query_body.with_clause) |wc| try self.compileWithClause(wc);
                    if (query_body.where_clause) |wc| try self.compileWhereClause(wc);
                    try self.compileSelectClause(query_body.select_clause);
                    try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
                },
                else => @panic("Not implemented"),
            }
        }

        const table = try self.scope_stack.currentScope();
        var variable_iterator = table.map.iterator();
        var variable_map = std.hash_map.AutoHashMap(runtime.VariableId, []const u8).init(allocator);
        while (variable_iterator.next()) |entry| {
            const slice = try self.addString(entry.key_ptr.*);
            try variable_map.put(entry.value_ptr.*, slice);
        }

        const instructions = try self.instruction_builder.patch(allocator);
        const regexes = try self.regexes.toOwnedSlice(allocator);
        const strings = try self.strings.toOwnedSlice(allocator);

        self.scope_stack.exitScope();
        return .{
            .instructions = instructions,
            .regexes = regexes,
            .strings = strings,
            .variable_map = variable_map,
            .allocator = allocator,
        };
    }

    /// Compilation of the with clause simply attaches binding metadata to each variable.
    fn compileWithClause(self: *Compiler, with_clause: ast.WithClause) CompilerError!void {
        for (with_clause.bindings) |binding| {
            try self.bindMetadata(binding.variable, binding.expression);
        }
    }

    fn bindMetadata(self: *Compiler, variable: ast.Variable, expression: ast.Expression) CompilerError!void {
        switch (expression) {
            .node_selector, .field_access, .child_navigation, .descendant_navigation, .variable => {
                const var_id = try self.scope_stack.getOrPut(variable.name);
                try self.binding_metadata.append(self.allocator, .{
                    .variable_id = var_id,
                    .navigation = .{ .expression = expression },
                    .emitted = false,
                });
            },
            .parenthesized => |parenthesized| {
                try self.bindMetadata(variable, parenthesized.*);
            },
            .string_literal,
            .regex_literal,
            .number_literal,
            .null_literal,
            => {
                const var_id = try self.scope_stack.getOrPut(variable.name);
                try self.binding_metadata.append(self.allocator, .{
                    .variable_id = var_id,
                    .navigation = .none,
                    .emitted = false,
                });
            },
            .object_literal, .array_literal, .tuple_literal => {
                // same as above, but not sure what to do with this.
                // should forceBound evaluate the potential inner exprs?
                const var_id = try self.scope_stack.getOrPut(variable.name);
                try self.binding_metadata.append(self.allocator, .{
                    .variable_id = var_id,
                    .navigation = .none,
                    .emitted = false,
                });
            },
            .subquery => {},
            .function_call => |fc| {
                // TODO: prelude functions
                if (!std.mem.eql(u8, "unnest", fc.name)) return error.InvalidUnnestArgument;
                if (fc.arguments.len != 1) return error.InvalidUnnestArgument;
                const sq = sqArg: {
                    var arg = fc.arguments[0];
                    while (arg == .parenthesized) arg = arg.parenthesized.*;
                    if (arg != .subquery) return error.InvalidUnnestArgument;
                    break :sqArg arg.subquery;
                };
                const var_id = try self.scope_stack.getOrPut(variable.name);
                try self.binding_metadata.append(self.allocator, .{
                    .variable_id = var_id,
                    .navigation = .{ .unnest_subquery = sq },
                    .emitted = false,
                });
            },
        }
    }

    fn forceBoundEvaluation(self: *Compiler, var_id: VariableId) CompilerError!void {
        for (self.binding_metadata.items) |*binding| {
            if (binding.variable_id == var_id) {
                if (binding.emitted) return;

                switch (binding.navigation) {
                    .expression => |expression| {
                        try self.navigateTo(expression);
                        try self.bindCursorTo(var_id);
                    },
                    .unnest_subquery => |sq| {
                        try self.scope_stack.enterScope();
                        defer self.scope_stack.exitScope();
                        if (sq.with_clause) |wc| try self.compileWithClause(wc);
                        if (sq.where_clause) |wc| try self.compileWhereClause(wc);
                        try self.assignProjectionToVariable(sq.select_clause.projection, var_id);
                    },
                    .none => {
                        try self.bindCursorTo(var_id);
                    },
                }
                binding.emitted = true;
                return;
            }
        }
        return error.InvalidVariableReference;
    }

    fn assignProjectionToVariable(
        self: *Compiler,
        projection: ast.Expression,
        var_id: VariableId,
    ) CompilerError!void {
        switch (projection) {
            .node_selector,
            .field_access,
            .child_navigation,
            .descendant_navigation,
            .variable,
            => {
                try self.navigateTo(projection);
                try self.bindCursorTo(var_id);
            },
            .parenthesized => |p| try self.assignProjectionToVariable(p.*, var_id),
            else => {
                const vs = try self.valueOf(projection);
                try self.bindValueTo(var_id, vs);
            },
        }
    }

    /// Force every variable referenced by `expr` to be evaluated, thus multiplying the NFA
    /// branches.
    fn forceEvaluation(self: *Compiler, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .variable => |variable| {
                const dep = self.scope_stack.get(variable.name) orelse return error.InvalidVariableReference;
                try self.forceBoundEvaluation(dep);
            },
            .field_access => |fa| try self.forceEvaluation(fa.base),
            .child_navigation => |cn| try self.forceEvaluation(cn.parent),
            .descendant_navigation => |dn| try self.forceEvaluation(dn.parent),
            .parenthesized => |p| try self.forceEvaluation(p.*),
            .node_selector, .string_literal, .regex_literal, .number_literal, .null_literal => {},
            else => @panic("Non-navigation expression as dependency"),
        }
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
        const var_id = try self.scope_stack.getOrPut(quantified.variable.name);

        try self.forceEvaluation(quantified.source);

        const probe_data: runtime.ProbeData = if (probe_negated) .nexists else .exists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        try self.navigateTo(quantified.source);
        try self.bindCursorTo(var_id);

        try self.binding_metadata.append(self.allocator, .{
            .variable_id = var_id,
            .navigation = .{ .expression = quantified.source },
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

        try self.forceEvaluation(is_null.expression);

        const probe_data: runtime.ProbeData = if (is_null.negated) .exists else .nexists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        try self.navigateTo(is_null.expression);
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
            const var_id = try self.materializeAsVariable(comparison.left);
            const owned_str = try self.addString(comparison.right.string_literal);

            try self.navigateToVariable(var_id);
            try self.instruction_builder.emit(.{ .rel = .{
                .relation = .equals,
                .a = .{ .node = .text },
                .b = .{ .literal = .{ .string = owned_str } },
            } });

            try self.instruction_builder.emitJump(success_label, .relates);
            try self.instruction_builder.emitJump(failure_label, .always);
            return;
        }

        if (comparison.right == .regex_literal) {
            const var_id = try self.materializeAsVariable(comparison.left);
            try self.navigateToVariable(var_id);

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

        const left_source = try self.valueOf(comparison.left);
        const right_source = try self.valueOf(comparison.right);

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

    /// Return a `VariableId` whose binding plan has been emitted such that the
    /// variable holds the node(s) denoted by `expr`. If `expr` is already a
    /// `.variable`, the existing id is reused; otherwise an anonymous variable
    /// is allocated and `expr` is registered as its navigation.
    fn materializeAsVariable(
        self: *Compiler,
        expr: ast.Expression,
    ) CompilerError!VariableId {
        return switch (expr) {
            .variable => |v| blk: {
                const var_id = self.scope_stack.get(v.name) orelse return error.InvalidVariableReference;
                try self.forceBoundEvaluation(var_id);
                break :blk var_id;
            },
            .field_access, .child_navigation, .descendant_navigation, .node_selector => blk: {
                const anon_id = try self.scope_stack.allocateAnonymous();
                try self.binding_metadata.append(self.allocator, .{
                    .variable_id = anon_id,
                    .navigation = .{ .expression = expr },
                    .emitted = false,
                });
                try self.forceBoundEvaluation(anon_id);
                break :blk anon_id;
            },
            .parenthesized => |p| try self.materializeAsVariable(p.*),
            // TODO: we should be able to support all expressions as variables
            else => @panic("TODO"),
        };
    }

    fn valueOf(self: *Compiler, expr: ast.Expression) CompilerError!runtime.ValueSource {
        return switch (expr) {
            .variable => |variable| {
                if (self.scope_stack.get(variable.name)) |var_id| {
                    try self.forceBoundEvaluation(var_id);
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
            => {
                const anon_id = try self.materializeAsVariable(expr);
                return runtime.ValueSource{ .variable_id = anon_id };
            },
            .parenthesized => |p| try self.valueOf(p.*),
            .object_literal => |obj| {
                const FieldSource = struct { key: []const u8, source: runtime.ValueSource };
                var sources = try self.allocator.alloc(FieldSource, obj.fields.len);
                defer self.allocator.free(sources);

                for (obj.fields, 0..) |field, i| {
                    switch (field) {
                        .variable => |variable| {
                            const var_id = self.scope_stack.get(variable.name) orelse
                                return error.InvalidVariableReference;
                            try self.forceBoundEvaluation(var_id);
                            sources[i] = .{
                                .key = try self.addString(variable.name),
                                .source = .{ .variable_id = var_id },
                            };
                        },
                        .key_value => |kv| {
                            const source = try self.valueOf(kv.value);
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
                const tmp = try self.scope_stack.allocateAnonymous();
                try self.instruction_builder.emit(.{ .end_build = tmp });
                return runtime.ValueSource{ .variable_id = tmp };
            },
            .array_literal => |arr| try self.compileListExpression(arr.elements),
            .tuple_literal => |tup| try self.compileListExpression(tup.elements),
            .subquery => |subquery| {
                const resume_label = self.instruction_builder.createLabel();
                const anon_variable = try self.scope_stack.allocateAnonymous();

                try self.instruction_builder.emitProbe(.{
                    .aggregate = .{
                        .variable = anon_variable,
                        .kind = .list,
                    },
                }, resume_label);
                if (subquery.with_clause) |wc| try self.compileWithClause(wc);
                if (subquery.where_clause) |wc| try self.compileWhereClause(wc);
                try self.compileSelectClause(subquery.select_clause);
                try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

                try self.instruction_builder.markLabel(resume_label);

                return .{ .variable_id = anon_variable };
            },
            .function_call => @panic("TODO"),
        };
    }

    fn compileListExpression(self: *Compiler, elements: []const ast.Expression) CompilerError!runtime.ValueSource {
        const sources = try self.allocator.alloc(runtime.ValueSource, elements.len);
        defer self.allocator.free(sources);

        for (elements, 0..) |elem, i| {
            sources[i] = try self.valueOf(elem);
        }

        try self.instruction_builder.emit(.{ .begin_build = .list });
        for (sources) |s| {
            try self.instruction_builder.emit(.{ .push_build = .{ .source = s, .name = null } });
        }
        const tmp = try self.scope_stack.allocateAnonymous();
        try self.instruction_builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }

    fn compileSelectClause(self: *Compiler, select_clause: ast.SelectClause) !void {
        const vs = try self.valueOf(select_clause.projection);
        try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
    }
};
