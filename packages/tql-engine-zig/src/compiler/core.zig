const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const runtime = @import("../runtime.zig");
const Condition = runtime.Condition;
const Instruction = runtime.Instruction;
const VariableId = runtime.VariableId;
const NodeKindId = runtime.NodeKindId;
const FieldId = runtime.FieldId;
const Address = runtime.Address;
const Relation = runtime.Relation;

const ast = @import("../ast.zig");
const pcre2 = @import("../pcre2.zig");

const LabelId = u32;

const BindingMetadata = struct {
    variable_id: VariableId,
    expression: ast.NavigationExpression,
    emitted: bool = false,
};

pub const Program = struct {
    instructions: []const Instruction,
    regexes: []pcre2.Regex,
    strings: []const []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.instructions);
        for (self.regexes) |*regex| {
            regex.deinit();
        }
        self.allocator.free(self.regexes);
        for (self.strings) |str| {
            self.allocator.free(str);
        }
        self.allocator.free(self.strings);
    }
};

pub const VariableTable = struct {
    map: std.StringHashMap(VariableId),
    next_id: VariableId,

    pub fn init(allocator: Allocator) VariableTable {
        return .{
            .map = std.StringHashMap(VariableId).init(allocator),
            .next_id = 0,
        };
    }

    pub fn deinit(self: *VariableTable) void {
        self.map.deinit();
    }

    pub fn getOrPut(self: *VariableTable, name: []const u8) !VariableId {
        const result = try self.map.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = self.next_id;
            self.next_id += 1;
        }
        return result.value_ptr.*;
    }

    pub fn get(self: *const VariableTable, name: []const u8) ?VariableId {
        return self.map.get(name);
    }
};

pub const InstructionBuilder = struct {
    instructions: std.ArrayList(Instruction),
    regexes: std.ArrayList(pcre2.Regex),
    strings: std.ArrayList([]const u8),
    allocator: Allocator,
    pending_labels: std.AutoHashMap(u32, std.ArrayList(usize)),
    resolved_labels: std.AutoHashMap(u32, Address),
    next_label_id: u32,

    pub fn init(allocator: Allocator) InstructionBuilder {
        return .{
            .instructions = std.ArrayList(Instruction){},
            .regexes = std.ArrayList(pcre2.Regex){},
            .strings = std.ArrayList([]const u8){},
            .allocator = allocator,
            .pending_labels = std.AutoHashMap(u32, std.ArrayList(usize)).init(allocator),
            .resolved_labels = std.AutoHashMap(u32, Address).init(allocator),
            .next_label_id = 0,
        };
    }

    pub fn deinit(self: *InstructionBuilder) void {
        self.instructions.deinit(self.allocator);

        for (self.regexes.items) |*regex| {
            regex.deinit();
        }
        self.regexes.deinit(self.allocator);

        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);

        var iter = self.pending_labels.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.pending_labels.deinit();

        self.resolved_labels.deinit();
    }

    pub fn addRegex(self: *InstructionBuilder, regex: pcre2.Regex) !usize {
        const index = self.regexes.items.len;
        try self.regexes.append(self.allocator, regex);
        return index;
    }

    pub fn addString(self: *InstructionBuilder, str: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, str);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    pub fn createLabel(self: *InstructionBuilder) LabelId {
        const label_id = self.next_label_id;
        self.next_label_id += 1;
        return @as(LabelId, label_id);
    }

    pub fn markLabel(self: *InstructionBuilder, label_id: LabelId) !void {
        const address = @as(Address, @intCast(self.instructions.items.len));
        try self.resolved_labels.put(label_id, address);
    }

    pub fn emit(self: *InstructionBuilder, instruction: Instruction) !void {
        try self.instructions.append(self.allocator, instruction);
    }

    pub fn emitJump(self: *InstructionBuilder, label_id: u32, mode: Condition) !void {
        const inst_index = self.instructions.items.len;

        // placeholder
        try self.instructions.append(self.allocator, Instruction{ .jmp = .{ .address = 0, .mode = mode } });

        const result = try self.pending_labels.getOrPut(label_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize){};
        }
        try result.value_ptr.append(self.allocator, inst_index);
    }

    pub fn emitProbe(self: *InstructionBuilder, mode: runtime.ProbeMode, on_success_label: u32) !void {
        const inst_index = self.instructions.items.len;

        try self.instructions.append(self.allocator, Instruction{ .probe = .{ .mode = mode, .on_success = 0 } });

        const result = try self.pending_labels.getOrPut(on_success_label);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize){};
        }
        try result.value_ptr.append(self.allocator, inst_index);
    }

    pub fn build(self: *InstructionBuilder) !Program {
        var pending_iter = self.pending_labels.iterator();
        while (pending_iter.next()) |entry| {
            const label_id = entry.key_ptr.*;
            const indices = entry.value_ptr.*;

            const address = self.resolved_labels.get(label_id) orelse {
                return error.UnresolvedLabel;
            };

            for (indices.items) |inst_index| {
                const inst = &self.instructions.items[inst_index];
                switch (inst.*) {
                    .jmp => |*jmp| jmp.address = address,
                    .probe => |*probe| probe.on_success = address,
                    else => return error.InvalidLabelReference,
                }
            }
        }

        const instructions = try self.instructions.toOwnedSlice(self.allocator);
        const regexes = try self.regexes.toOwnedSlice(self.allocator);
        const strings = try self.strings.toOwnedSlice(self.allocator);

        return Program{
            .instructions = instructions,
            .regexes = regexes,
            .strings = strings,
            .allocator = self.allocator,
        };
    }
};

// FIXME: Please don't do this...
// fuck it actually affects query results right now...
const ROOT_NAME = &[_]u8{0};

pub const Compiler = struct {
    allocator: Allocator,
    variables: VariableTable,
    language: *ts.Language,
    bindings: std.ArrayList(BindingMetadata),

    // FIXME: we're supposed to detect the language
    pub fn init(allocator: Allocator, language: *ts.Language) Compiler {
        return .{
            .allocator = allocator,
            .variables = VariableTable.init(allocator),
            .language = language,
            .bindings = std.ArrayList(BindingMetadata){},
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.variables.deinit();
        self.bindings.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler, source: ast.SourceFile) !Program {
        var builder = InstructionBuilder.init(self.allocator);
        defer builder.deinit();

        // FIXME: we're supposed to search for main
        // It would be nice if we can compile just the query body though, since that gives
        // a valid program.
        for (source.items) |item| {
            switch (item) {
                .query => |query| try self.compileQueryBody(&builder, query.body),
                else => {
                    @panic("Not implemented");
                },
            }
        }

        return try builder.build();
    }

    fn compileQueryBody(self: *Compiler, builder: *InstructionBuilder, body: ast.QueryBody) !void {
        const root_id = try self.variables.getOrPut(ROOT_NAME);
        try builder.emit(.{ .asn = .{
            .variable_id = root_id,
            .source = .{ .node = .this },
        } });

        if (body.from_clause) |from_clause| {
            try self.compileFromClause(from_clause);
        }

        if (body.where_clause) |where_clause| {
            try self.compileWhereClause(builder, where_clause);
        }

        try self.compileSelectClause(builder, body.select_clause);
    }

    fn compileFromClause(self: *Compiler, from_clause: ast.FromClause) !void {
        for (from_clause.bindings) |binding| {
            try self.compileBinding(binding);
        }
    }

    fn compileBinding(self: *Compiler, binding: ast.Binding) !void {
        const var_id = try self.variables.getOrPut(binding.variable.name);

        try self.bindings.append(self.allocator, .{
            .variable_id = var_id,
            .expression = binding.expression,
            .emitted = false,
        });
    }

    fn ensureRootNavigated(self: *Compiler, builder: *InstructionBuilder) anyerror!void {
        const root_id = self.variables.get(ROOT_NAME) orelse
            @panic("Dependency variable not found");
        try builder.emit(.{ .trv = .{ .variable_id = root_id } });
    }

    fn ensureVariableNavigated(self: *Compiler, builder: *InstructionBuilder, var_id: VariableId) anyerror!void {
        for (self.bindings.items) |*binding| {
            if (binding.variable_id == var_id) {
                if (binding.emitted) return;

                try self.ensureExpressionDependencies(builder, binding.expression);
                try self.compileNavigationExpression(builder, binding.expression);
                try builder.emit(.{ .asn = .{
                    .variable_id = var_id,
                    .source = .{ .node = .this },
                } });
                binding.emitted = true;
                return;
            }
        }
        @panic("Variable not found in bindings");
    }

    fn ensureExpressionDependencies(self: *Compiler, builder: *InstructionBuilder, expr: ast.NavigationExpression) anyerror!void {
        switch (expr) {
            .variable => |variable| {
                const dep_var_id = self.variables.get(variable.name) orelse
                    @panic("Dependency variable not found");
                try self.ensureVariableNavigated(builder, dep_var_id);
            },
            .field_access => |field_access| {
                switch (field_access.base) {
                    .variable => |variable| {
                        const dep_var_id = self.variables.get(variable.name) orelse
                            @panic("Base variable not found");
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
                        const dep_var_id = self.variables.get(variable.name) orelse
                            @panic("Parent variable not found");
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
                            @panic("Parent variable not found");
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
            .query_call => {
                @panic("Query call not implemented");
            },
        }
    }

    fn compileNavigationExpression(
        self: *Compiler,
        builder: *InstructionBuilder,
        expr: ast.NavigationExpression,
    ) anyerror!void {
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
                try self.compileNavigationExpression(builder, parenthesized.*);
            },
            .query_call => {
                @panic("Query call as child navigation parent not yet implemented");
            },
        }
    }

    fn compileFieldAccess(self: *Compiler, builder: *InstructionBuilder, field_access: *ast.FieldAccess) anyerror!void {
        try self.compileNavigationExpression(builder, field_access.base);
        const field_id = self.language.fieldIdForName(field_access.field);
        try builder.emit(.{ .trv = .{ .field = field_id } });
    }

    fn compileChildNavigation(self: *Compiler, builder: *InstructionBuilder, child_nav: *ast.ChildNavigation) anyerror!void {
        try self.compileNavigationExpression(builder, child_nav.parent);
        try builder.emit(.{ .trv = .{ .child = {} } });

        // FIXME: Why can't I do self.compileNavigationExpression(builder, child_nav.child)?
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

    fn compileDescendantNavigation(self: *Compiler, builder: *InstructionBuilder, desc_nav: *ast.DescendantNavigation) anyerror!void {
        try self.compileNavigationExpression(builder, desc_nav.parent);

        try builder.emit(.{ .trv = .{ .descendant = {} } });

        // FIXME: Why can't I do self.compileNavigationExpression(builder, desc_nav.child)?
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

    fn compileVariableSelector(self: *Compiler, builder: *InstructionBuilder, variable: ast.Variable) anyerror!void {
        if (self.variables.get(variable.name)) |parent_var_id| {
            try builder.emit(.{ .trv = .{ .variable_id = parent_var_id } });
        } else {
            @panic("Variable not found");
        }
    }

    fn compileNodeSelector(self: *Compiler, builder: *InstructionBuilder, node_selector: ast.NodeSelector) !void {
        const kind_id = self.language.idForNodeKind(node_selector.node_type, true);

        // FIXME: This can't be right
        try builder.emit(.{ .trv = .{ .descendant = {} } });
        try builder.emit(.{ .rel = .{
            .relation = .equals,
            .a = .{ .node = .kind },
            .b = .{ .literal = .{ .kind_id = kind_id } },
        } });
        try builder.emit(.{ .halt = .{ .condition = .not_relates } });
    }

    fn compileWhereClause(self: *Compiler, builder: *InstructionBuilder, where_clause: ast.WhereClause) !void {
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
    ) !void {
        switch (predicate) {
            .comparison => |comparison| {
                try self.compileComparison(builder, comparison, success_label, failure_label);
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
            .variable => |variable| {
                if (self.variables.get(variable.name)) |var_id| {
                    try self.ensureVariableNavigated(builder, var_id);

                    try builder.emit(.{ .rel = .{
                        .relation = .equals,
                        .a = .{ .variable_id = var_id },
                        .b = .{ .literal = .{ .nothing = {} } },
                    } });
                    try builder.emit(.{ .halt = .{ .condition = .relates } });
                } else {
                    @panic("Variable not found in predicate");
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
    ) anyerror!void {
        switch (quantified.quantifier) {
            .exists => {
                const probe_success_label = builder.createLabel();

                const var_id = self.variables.get(quantified.variable.name) orelse
                    @panic("Quantified variable not found");

                try self.ensureVariableNavigated(builder, var_id);

                const probe_mode: runtime.ProbeMode = if (negated) .nexists else .exists;
                try builder.emitProbe(probe_mode, probe_success_label);

                const inner_success_label = builder.createLabel();
                const inner_failure_label = builder.createLabel();
                try self.compilePredicate(builder, quantified.predicate.*, inner_success_label, inner_failure_label);

                try builder.markLabel(inner_success_label);
                try builder.emit(.yield);

                try builder.markLabel(inner_failure_label);
                try builder.emit(.{ .halt = .{ .condition = .always } });

                try builder.markLabel(probe_success_label);
                try builder.emitJump(outer_success_label, .always);
            },
            .forall => {
                @panic("forall quantifier not yet implemented");
            },
        }
    }

    fn compileComparison(
        self: *Compiler,
        builder: *InstructionBuilder,
        comparison: ast.Comparison,
        // there's definitely a simplification here
        success_label: LabelId,
        failure_label: LabelId,
    ) !void {
        if (comparison.left == .variable and comparison.right == .string_literal) {
            const variable = comparison.left.variable;
            if (self.variables.get(variable.name)) |var_id| {
                try self.ensureVariableNavigated(builder, var_id);

                const owned_str = try builder.addString(comparison.right.string_literal);

                try builder.emit(.{ .trv = .{ .variable_id = var_id } });
                try builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .string = owned_str } },
                } });

                try builder.emitJump(success_label, .relates);
                try builder.emitJump(failure_label, .always);
                return;
            } else {
                @panic("Variable not found in comparison");
            }
        }

        if (comparison.left == .variable and comparison.right == .regex_literal) {
            const variable = comparison.left.variable;
            if (self.variables.get(variable.name)) |var_id| {
                try self.ensureVariableNavigated(builder, var_id);

                try builder.emit(.{ .trv = .{ .variable_id = var_id } });

                const regex = try pcre2.Regex.compile(comparison.right.regex_literal);
                const regex_index = try builder.addRegex(regex);

                try builder.emit(.{ .rel = .{
                    .relation = .like,
                    .a = .{ .node = .text },
                    .b = .{ .literal = .{ .regex = builder.regexes.items[regex_index] } },
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
            } else {
                @panic("Variable not found in comparison");
            }
        }

        const left_source = try self.compileExpression(builder, comparison.left);
        const right_source = try self.compileExpression(builder, comparison.right);

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

    fn compileExpression(self: *Compiler, builder: *InstructionBuilder, expr: ast.Expression) !runtime.ValueSource {
        return switch (expr) {
            .variable => |variable| {
                if (self.variables.get(variable.name)) |var_id| {
                    try self.ensureVariableNavigated(builder, var_id);
                    return runtime.ValueSource{ .variable_id = var_id };
                } else {
                    @panic("Variable not found in expression");
                }
            },
            .string_literal => |str| {
                const owned_str = try builder.addString(str);
                return runtime.ValueSource{
                    .literal = .{ .string = owned_str },
                };
            },
            .number_literal => |_| {
                @panic("Number literals not yet implemented");
            },
            .regex_literal => |pattern| {
                const regex = try pcre2.Regex.compile(pattern);
                const regex_index = try builder.addRegex(regex);
                return runtime.ValueSource{
                    .literal = .{ .regex = builder.regexes.items[regex_index] },
                };
            },
            .field_access => |field_access| {
                _ = field_access;
                @panic("Field access in expressions not yet implemented");
            },
            else => @panic("Expression type not yet implemented"),
        };
    }

    fn compileSelectClause(self: *Compiler, builder: *InstructionBuilder, select_clause: ast.SelectClause) !void {
        switch (select_clause.projection) {
            .variable => |variable| {
                if (self.variables.get(variable.name)) |var_id| {
                    try self.ensureVariableNavigated(builder, var_id);
                    try builder.emit(.{ .trv = .{ .variable_id = var_id } });
                }
                try builder.emit(.yield);
            },
            else => @panic("Only variable projection supported for now"),
        }

        try builder.emit(.{ .halt = .{ .condition = .always } });
    }
};
