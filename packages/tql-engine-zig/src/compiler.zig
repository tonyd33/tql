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

pub const InstructionBuilder = @import("compiler/instruction_builder.zig").InstructionBuilder;
const CompilerError = @import("compiler/types.zig").CompilerError;

const LabelId = u32;
const VariableTable = std.StringHashMap(VariableId);

const DOT_NAME = "__dot";

pub const Compiler = struct {
    language: *const ts.Language,

    allocator: Allocator,
    instruction_builder: InstructionBuilder,
    variables: VariableTable,
    next_id: VariableId,

    regexes: std.ArrayList(pcre2.Regex),
    strings: std.ArrayList([]const u8),

    // FIXME: we're supposed to detect the language
    pub fn init(allocator: Allocator, language: *const ts.Language) Compiler {
        const strings = std.ArrayList([]const u8).empty;
        const regexes = std.ArrayList(pcre2.Regex).empty;
        const instruction_builder = InstructionBuilder.init(allocator);
        return .{
            .allocator = allocator,
            .variables = VariableTable.init(allocator),
            .next_id = 0,
            .language = language,
            .regexes = regexes,
            .strings = strings,
            .instruction_builder = instruction_builder,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instruction_builder.deinit();

        self.variables.deinit();

        for (self.regexes.items) |*regex| {
            regex.deinit();
        }
        self.regexes.deinit(self.allocator);

        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    fn putVariable(self: *Compiler, name: []const u8) CompilerError!VariableId {
        const result = try self.variables.getOrPut(name);
        if (!result.found_existing) {
            result.value_ptr.* = self.next_id;
            self.next_id += 1;
        }
        return result.value_ptr.*;
    }

    fn allocateAnonymous(self: *Compiler) CompilerError!VariableId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
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
        const dot_id = try self.putVariable(DOT_NAME);
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = dot_id, .source = .{ .node = .this } } });

        for (source.items) |item| {
            switch (item) {
                .query => |query| {
                    try self.compileTopLevel(query.body);
                    try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
                },
                .expression => |expr| {
                    try self.compileTopLevel(expr);
                    try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
                },
                else => @panic("Not implemented"),
            }
        }

        var variable_map = std.hash_map.AutoHashMap(runtime.VariableId, []const u8).init(allocator);
        var variable_iterator = self.variables.iterator();
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

    // Compile expression as top-level statement: pipe steps update dot, final step yields.
    fn compileTopLevel(self: *Compiler, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .pipe_expression => |pe| {
                try self.compileTopLevelStep(pe.left);
                try self.compileTopLevel(pe.right);
            },
            .bind_expression => |be| {
                const var_id = try self.putVariable(be.variable.name);
                const vs = try self.compileExpression(be.expression);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = var_id, .source = vs } });
            },
            else => {
                const vs = try self.compileExpression(expr);
                try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
            },
        }
    }

    // Compile a non-final pipeline step: update dot or bind variable, no yield.
    fn compileTopLevelStep(self: *Compiler, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .pipe_expression => |pe| {
                try self.compileTopLevelStep(pe.left);
                try self.compileTopLevelStep(pe.right);
            },
            .bind_expression => |be| {
                const var_id = try self.putVariable(be.variable.name);
                const vs = try self.compileExpression(be.expression);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = var_id, .source = vs } });
            },
            else => {
                const anon_id = try self.allocateAnonymous();
                const vs = try self.compileExpression(expr);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = anon_id, .source = vs } });
                try self.variables.put(DOT_NAME, anon_id);
            },
        }
    }

    // Compile a pipe_expression embedded in another expression (collect into list).
    fn compilePipeAsValue(self: *Compiler, expr: ast.Expression, var_id: VariableId) CompilerError!void {
        const saved_dot = self.variables.get(DOT_NAME).?;
        switch (expr) {
            .pipe_expression => |pe| {
                try self.compilePipeStepAsValue(pe.left);
                try self.compilePipeAsValue(pe.right, var_id);
            },
            .bind_expression => |be| {
                const bid = try self.putVariable(be.variable.name);
                const vs = try self.compileExpression(be.expression);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = bid, .source = vs } });
            },
            else => {
                const vs = try self.compileExpression(expr);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = var_id, .source = vs } });
            },
        }
        try self.variables.put(DOT_NAME, saved_dot);
    }

    fn compilePipeStepAsValue(self: *Compiler, expr: ast.Expression) CompilerError!void {
        switch (expr) {
            .pipe_expression => |pe| {
                try self.compilePipeStepAsValue(pe.left);
                try self.compilePipeStepAsValue(pe.right);
            },
            .bind_expression => |be| {
                const var_id = try self.putVariable(be.variable.name);
                const vs = try self.compileExpression(be.expression);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = var_id, .source = vs } });
            },
            else => {
                const anon_id = try self.allocateAnonymous();
                const vs = try self.compileExpression(expr);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = anon_id, .source = vs } });
                try self.variables.put(DOT_NAME, anon_id);
            },
        }
    }

    fn compileGuardExpr(
        self: *Compiler,
        expr: ast.Expression,
        failure_label: LabelId,
    ) CompilerError!void {
        switch (expr) {
            .comparison => |c| try self.compileComparison(c.*, failure_label),
            .is_null => |p| try self.compileIsNull(p.*),
            .logical_and => |la| {
                try self.compileGuardExpr(la.left, failure_label);
                try self.compileGuardExpr(la.right, failure_label);
            },
            .logical_or => |lo| {
                const right_label = self.instruction_builder.createLabel();
                const skip_label = self.instruction_builder.createLabel();

                try self.compileGuardExpr(lo.left, right_label);
                try self.instruction_builder.emitJump(skip_label, .always);

                try self.instruction_builder.markLabel(right_label);
                try self.compileGuardExpr(lo.right, failure_label);

                try self.instruction_builder.markLabel(skip_label);
            },
            .logical_not => |ln| {
                if (ln.predicate == .quantified) {
                    try self.compileQuantified(ln.predicate.quantified.*, true);
                } else {
                    const inner_failure_label = self.instruction_builder.createLabel();

                    try self.compileGuardExpr(ln.predicate, inner_failure_label);
                    try self.instruction_builder.emitJump(failure_label, .always);

                    try self.instruction_builder.markLabel(inner_failure_label);
                }
            },
            .quantified => |q| try self.compileQuantified(q.*, false),
            .parenthesized => |p| try self.compileGuardExpr(p.*, failure_label),
            else => return error.InvalidGuardExpression,
        }
    }

    fn compileQuantified(
        self: *Compiler,
        quantified: ast.QuantifiedExpression,
        negated: bool,
    ) CompilerError!void {
        const body_negated = quantified.quantifier == .all;
        const probe_negated = negated != body_negated;

        const probe_resume_label = self.instruction_builder.createLabel();

        const probe_data: runtime.ProbeData = if (probe_negated) .nexists else .exists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        _ = try self.compileExpression(quantified.source);

        const saved_dot = self.variables.get(DOT_NAME).?;

        const dot_id = try self.allocateAnonymous();
        try self.variables.put(DOT_NAME, dot_id);
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = dot_id, .source = .{ .node = .this } } });

        const inner_failure_label = self.instruction_builder.createLabel();
        if (body_negated) {
            try self.compileGuardExpr(quantified.predicate.*, inner_failure_label);
            try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
            try self.instruction_builder.markLabel(inner_failure_label);
            try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
        } else {
            try self.compileGuardExpr(quantified.predicate.*, inner_failure_label);
            try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
            try self.instruction_builder.markLabel(inner_failure_label);
            try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });
        }

        try self.variables.put(DOT_NAME, saved_dot);

        try self.instruction_builder.markLabel(probe_resume_label);
    }

    fn compileIsNull(
        self: *Compiler,
        is_null: ast.IsNullExpr,
    ) CompilerError!void {
        const probe_resume_label = self.instruction_builder.createLabel();

        const probe_data: runtime.ProbeData = if (is_null.negated) .exists else .nexists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        _ = try self.compileExpression(is_null.expression);
        try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .node = .this } } });
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

        try self.instruction_builder.markLabel(probe_resume_label);
    }

    fn compileComparison(
        self: *Compiler,
        comparison: ast.Comparison,
        failure_label: LabelId,
    ) CompilerError!void {
        if (comparison.right == .string_literal) {
            const var_id = try self.ensureVariable(try self.compileExpression(comparison.left));
            const owned_str = try self.addString(comparison.right.string_literal);

            // TODO: need a text() function. that's why this is so awkward.
            try self.instruction_builder.emit(.{ .trv = .{ .variable_id = var_id } });
            try self.instruction_builder.emit(.{ .rel = .{
                .relation = .equals,
                .a = .{ .node = .text },
                .b = .{ .literal = .{ .string = owned_str } },
            } });

            try self.instruction_builder.emitJump(failure_label, .not_relates);
            return;
        }

        if (comparison.right == .regex_literal) {
            const var_id = try self.ensureVariable(try self.compileExpression(comparison.left));
            try self.instruction_builder.emit(.{ .trv = .{ .variable_id = var_id } });

            const regex = try pcre2.Regex.compile(comparison.right.regex_literal);
            const regex_index = try self.addRegex(regex);

            try self.instruction_builder.emit(.{ .rel = .{
                .relation = .like,
                .a = .{ .node = .text },
                .b = .{ .literal = .{ .regex = self.regexes.items[regex_index] } },
            } });

            switch (comparison.operator) {
                .regex_match => try self.instruction_builder.emitJump(failure_label, .not_relates),
                .regex_not_match => try self.instruction_builder.emitJump(failure_label, .relates),
                else => unreachable,
            }
            return;
        }

        const left_source = try self.compileExpression(comparison.left);
        const right_source = try self.compileExpression(comparison.right);

        switch (comparison.operator) {
            .eq => {
                try self.instruction_builder.emit(.{ .rel = .{ .relation = .equals, .a = left_source, .b = right_source } });
                try self.instruction_builder.emitJump(failure_label, .not_relates);
            },
            .ne => {
                try self.instruction_builder.emit(.{ .rel = .{ .relation = .equals, .a = left_source, .b = right_source } });
                try self.instruction_builder.emitJump(failure_label, .relates);
            },
            .regex_match => {
                try self.instruction_builder.emit(.{ .rel = .{ .relation = .like, .a = left_source, .b = right_source } });
                try self.instruction_builder.emitJump(failure_label, .not_relates);
            },
            .regex_not_match => {
                try self.instruction_builder.emit(.{ .rel = .{ .relation = .like, .a = left_source, .b = right_source } });
                try self.instruction_builder.emitJump(failure_label, .relates);
            },
        }
    }

    fn compileExpression(self: *Compiler, expr: ast.Expression) CompilerError!runtime.ValueSource {
        switch (expr) {
            .variable => |variable| {
                const var_id = self.variables.get(variable.name) orelse return error.InvalidVariableReference;
                return .{ .variable_id = var_id };
            },
            .node_selector => |node_selector| {
                const kind_id = self.language.idForNodeKind(node_selector.node_type, true);
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .node = .kind },
                    .b = .{ .literal = .{ .kind_id = kind_id } },
                } });
                try self.instruction_builder.emit(.{ .halt = .{ .condition = .not_relates } });
                return .{ .node = .this };
            },
            .field_access => |field_access| {
                const base = try self.compileExpression(field_access.base);
                if (base == .variable_id) try self.instruction_builder.emit(.{ .trv = .{ .variable_id = base.variable_id } });
                const field_id = self.language.fieldIdForName(field_access.field);
                try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
                return .{ .node = .this };
            },
            .child_navigation => |child_nav| {
                const parent = try self.compileExpression(child_nav.parent);
                if (parent == .variable_id) try self.instruction_builder.emit(.{ .trv = .{ .variable_id = parent.variable_id } });
                try self.instruction_builder.emit(.{ .trv = .{ .child = {} } });
                _ = try self.compileExpression(child_nav.child);
                return .{ .node = .this };
            },
            .descendant_navigation => |desc_nav| {
                const parent = try self.compileExpression(desc_nav.parent);
                if (parent == .variable_id) try self.instruction_builder.emit(.{ .trv = .{ .variable_id = parent.variable_id } });
                try self.instruction_builder.emit(.{ .trv = .{ .descendant = {} } });
                _ = try self.compileExpression(desc_nav.descendant);
                return .{ .node = .this };
            },
            .dot_field_access => |dfa| {
                const dot_id = self.variables.get(DOT_NAME) orelse return error.InvalidVariableReference;
                try self.instruction_builder.emit(.{ .trv = .{ .variable_id = dot_id } });
                const field_id = self.language.fieldIdForName(dfa.field);
                try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
                return .{ .node = .this };
            },
            .identity => {
                const dot_id = self.variables.get(DOT_NAME) orelse return error.InvalidVariableReference;
                try self.instruction_builder.emit(.{ .trv = .{ .variable_id = dot_id } });
                return .{ .node = .this };
            },
            .string_literal => |str| {
                const owned_str = try self.addString(str);
                return .{ .literal = .{ .string = owned_str } };
            },
            .number_literal => |number| return .{ .literal = .{ .uint = number } },
            .null_literal => return .{ .literal = .{ .nothing = {} } },
            .regex_literal => |pattern| {
                const regex = try pcre2.Regex.compile(pattern);
                const regex_index = try self.addRegex(regex);
                return .{ .literal = .{ .regex = self.regexes.items[regex_index] } };
            },
            .object_literal => |obj| {
                const FieldSource = struct { key: []const u8, source: runtime.ValueSource };
                var sources = try self.allocator.alloc(FieldSource, obj.fields.len);
                defer self.allocator.free(sources);

                for (obj.fields, 0..) |field, i| {
                    switch (field) {
                        .variable => |variable| {
                            const var_id = self.variables.get(variable.name) orelse
                                return error.InvalidVariableReference;
                            sources[i] = .{
                                .key = try self.addString(variable.name),
                                .source = .{ .variable_id = var_id },
                            };
                        },
                        .key_value => |kv| {
                            sources[i] = .{
                                .key = try self.addString(kv.key),
                                .source = try self.compileExpression(kv.value),
                            };
                        },
                    }
                }

                try self.instruction_builder.emit(.{ .begin_build = .record });
                for (sources) |fs| {
                    try self.instruction_builder.emit(.{ .push_build = .{ .source = fs.source, .name = fs.key } });
                }
                const tmp = try self.allocateAnonymous();
                try self.instruction_builder.emit(.{ .end_build = tmp });
                return .{ .variable_id = tmp };
            },
            .array_literal => |arr| return try self.compileListExpression(arr.elements),
            .tuple_literal => |tup| return try self.compileListExpression(tup.elements),
            .parenthesized => |p| return try self.compileExpression(p.*),
            .bind_expression => return error.InvalidGuardExpression,
            .pipe_expression => {
                const resume_label = self.instruction_builder.createLabel();
                const anon_variable = try self.allocateAnonymous();

                try self.instruction_builder.emitProbe(.{
                    .aggregate = .{ .variable = anon_variable, .kind = .list },
                }, resume_label);
                try self.compileTopLevel(expr);
                try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

                try self.instruction_builder.markLabel(resume_label);
                return .{ .variable_id = anon_variable };
            },
            .function_call => |fc| {
                if (std.mem.eql(u8, fc.name, "select")) {
                    return self.compileBuiltinSelect(fc);
                } else if (std.mem.eql(u8, fc.name, "unnest")) {
                    return self.compileBuiltinUnnest(fc);
                } else {
                    return error.InvalidVariableReference;
                }
            },
            .comparison, .is_null, .logical_and, .logical_or, .logical_not, .quantified => return error.InvalidGuardExpression,
        }
    }

    fn compileBuiltinSelect(self: *Compiler, fc: ast.FunctionCall) CompilerError!runtime.ValueSource {
        if (fc.arguments.len != 1) return error.InvalidGuardExpression;
        const expr = fc.arguments[0];

        const failure_label = self.instruction_builder.createLabel();
        try self.compileGuardExpr(expr, failure_label);
        const skip_label = self.instruction_builder.createLabel();
        try self.instruction_builder.emitJump(skip_label, .always);

        try self.instruction_builder.markLabel(failure_label);
        try self.instruction_builder.emit(.{ .halt = .{ .condition = .always } });

        try self.instruction_builder.markLabel(skip_label);
        const dot_id = self.variables.get(DOT_NAME) orelse return error.InvalidVariableReference;

        return .{ .variable_id = dot_id };
    }

    fn compileBuiltinUnnest(self: *Compiler, fc: ast.FunctionCall) CompilerError!runtime.ValueSource {
        if (fc.arguments.len != 1) return error.InvalidUnnestArgument;
        var arg = fc.arguments[0];
        while (arg == .parenthesized) arg = arg.parenthesized.*;
        if (arg != .pipe_expression) return error.InvalidUnnestArgument;
        const anon_id = try self.allocateAnonymous();
        try self.compilePipeAsValue(arg, anon_id);
        return .{ .variable_id = anon_id };
    }

    fn ensureVariable(self: *Compiler, vs: runtime.ValueSource) CompilerError!VariableId {
        return switch (vs) {
            .variable_id => |id| id,
            .node => blk: {
                const anon_id = try self.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = anon_id, .source = .{ .node = .this } } });
                break :blk anon_id;
            },
            .literal => return error.InvalidVariableReference,
        };
    }

    fn compileListExpression(self: *Compiler, elements: []const ast.Expression) CompilerError!runtime.ValueSource {
        const sources = try self.allocator.alloc(runtime.ValueSource, elements.len);
        defer self.allocator.free(sources);

        for (elements, 0..) |elem, i| {
            sources[i] = try self.compileExpression(elem);
        }

        try self.instruction_builder.emit(.{ .begin_build = .list });
        for (sources) |s| {
            try self.instruction_builder.emit(.{ .push_build = .{ .source = s, .name = null } });
        }
        const tmp = try self.allocateAnonymous();
        try self.instruction_builder.emit(.{ .end_build = tmp });
        return .{ .variable_id = tmp };
    }
};
