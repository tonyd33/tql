const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

const ir = @import("ir.zig");
const Instruction = ir.Instruction;
const VariableId = ir.VariableId;
const NodeKindId = ir.NodeKindId;
const FieldId = ir.FieldId;
const Address = ir.Address;
const Relation = ir.Relation;
const ProgramImage = ir.ProgramImage;

const ast = @import("ast.zig");
const pcre2 = @import("regex.zig");

pub const InstructionBuilder = @import("compiler/instruction_builder.zig").InstructionBuilder;
const CompilerError = @import("compiler/types.zig").CompilerError;
const variables = @import("compiler/variables.zig");
const VariableTable = variables.VariableTable;
const Namespace = variables.Namespace;

const LabelId = u32;

const FunctionDeclaration = struct {
    entry_label: LabelId,
    param_vars: []const VariableId,
};

pub const Compiler = struct {
    language: *const ts.Language,

    allocator: Allocator,
    instruction_builder: InstructionBuilder,
    functions: std.StringHashMap(FunctionDeclaration),

    variables: VariableTable,

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
            .functions = std.StringHashMap(FunctionDeclaration).init(allocator),
            .language = language,
            .regexes = regexes,
            .strings = strings,
            .instruction_builder = instruction_builder,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instruction_builder.deinit();

        self.variables.deinit();

        var fn_iter = self.functions.valueIterator();
        while (fn_iter.next()) |info| {
            self.allocator.free(info.param_vars);
        }
        self.functions.deinit();

        for (self.regexes.items) |*regex| {
            regex.deinit();
        }
        self.regexes.deinit(self.allocator);

        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    fn bindValue(self: *Compiler) CompilerError!ir.ValueSource {
        const tmp = self.variables.allocateAnonymous();
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = tmp, .source = .{ .current = .value } } });
        return .{ .variable_id = tmp };
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
        var top_level_ns = self.variables.newNamespace();
        defer top_level_ns.deinit();

        // 1st pass: collect function declarations
        for (source.items) |item| {
            switch (item) {
                .query => |query| {
                    if (self.functions.contains(query.name)) return error.DuplicateFunctionDefinition;
                    const entry_label = self.instruction_builder.createLabel();
                    const param_vars = try self.allocator.alloc(VariableId, query.parameters.len);
                    for (param_vars) |*param_var| {
                        param_var.* = self.variables.allocateAnonymous();
                    }
                    try self.functions.put(query.name, .{
                        .entry_label = entry_label,
                        .param_vars = param_vars,
                    });
                },
                .expression => {},
                else => @panic("Not implemented"),
            }
        }

        // 2nd pass: compile expressions
        for (source.items) |item| {
            switch (item) {
                .query => {},
                .expression => |expr| {
                    const vs = try self.compileExpression(&top_level_ns, expr);
                    try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
                    try self.instruction_builder.emit(.halt);
                },
                else => @panic("Not implemented"),
            }
        }

        // 3rd pass: compile function bodies
        // we do this on the third pass instead of the second because the
        // function bodies should not be emitted as the first instruction
        // this is weird and we should come up with a better solution
        for (source.items) |item| {
            switch (item) {
                .query => |query| {
                    const info = self.functions.get(query.name).?;
                    var def_ns = self.variables.newNamespace();
                    defer def_ns.deinit();
                    for (query.parameters, info.param_vars) |param, var_id| {
                        const owned_name = try self.addString(param.name.name);
                        try self.variables.bind(&def_ns, owned_name, var_id);
                    }
                    try self.instruction_builder.markLabel(info.entry_label);
                    const vs = try self.compileExpression(&def_ns, query.body);
                    try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
                    try self.instruction_builder.emit(.halt);
                },
                .expression => {},
                else => @panic("Not implemented"),
            }
        }

        const instructions = try self.instruction_builder.patch(allocator);
        const regexes = try self.regexes.toOwnedSlice(allocator);
        const strings = try self.strings.toOwnedSlice(allocator);

        return .{
            .instructions = instructions,
            .regexes = regexes,
            .strings = strings,
            .variable_map = self.variables.moveNames(),
            .allocator = allocator,
        };
    }

    /// Compile an expression to a ValueSource.
    ///
    /// Stability of the returned ValueSource is only guaranteed right after
    /// function execution. Callers must bind it to preserve it.
    ///
    /// Postconditions:
    /// - fanout may have occurred
    /// - cursor is well-defined: it is the value of the compiled expression
    ///   itself (i.e. equivalent to the returned ValueSource)
    /// - environment is mutated in a way that shouldn't be observable by
    ///   callers
    /// - no top-level yields have been emitted (yields behind effect handling
    ///   frames are permitted)
    ///
    fn compileExpression(self: *Compiler, ns: *Namespace, expr: ast.Expression) CompilerError!ir.ValueSource {
        switch (expr) {
            .variable => |variable| {
                const var_id = self.variables.resolve(ns, variable.name) orelse return error.InvalidVariableReference;
                return .{ .variable_id = var_id };
            },
            .string_literal => |str| {
                const owned_str = try self.addString(str);
                return .{ .literal = .{ .string = owned_str } };
            },
            .number_literal => |number| return .{ .literal = .{ .int = number } },
            .null_literal => return .{ .literal = .{ .nothing = {} } },
            .regex_literal => |pattern| {
                const regex = try pcre2.Regex.compile(pattern);
                const regex_index = try self.addRegex(regex);
                return .{ .literal = .{ .regex = self.regexes.items[regex_index] } };
            },
            .function_call => |fc| {
                if (self.functions.get(fc.name)) |info| {
                    // TODO: what to do about shadowing builtins?
                    if (fc.arguments.len != info.param_vars.len) return error.InvalidArguments;
                    for (fc.arguments, info.param_vars) |arg_expr, param_var| {
                        const arg_vs = try self.compileExpression(ns, arg_expr);
                        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = param_var, .source = arg_vs } });
                    }
                    try self.instruction_builder.emitCall(info.entry_label);
                    return try self.bindValue();
                } else if (std.mem.eql(u8, fc.name, "text")) {
                    if (fc.arguments.len != 0) return error.InvalidArguments;
                    return .{ .current = .text };
                } else if (std.mem.eql(u8, fc.name, "length")) {
                    if (fc.arguments.len != 0) return error.InvalidArguments;
                    return .{ .current = .length };
                } else if (std.mem.eql(u8, fc.name, "select")) {
                    return self.compileBuiltinSelect(ns, fc);
                } else if (std.mem.eql(u8, fc.name, "unnest")) {
                    return self.compileBuiltinUnnest(ns, fc);
                } else if (std.mem.eql(u8, fc.name, "any") or std.mem.eql(u8, fc.name, "all")) {
                    try self.compileBuiltinQuantified(ns, fc, false);
                    return .{ .literal = .{ .bool = true } };
                } else {
                    return error.InvalidVariableReference;
                }
            },
            .field_access => |fa| {
                const base = try self.compileExpression(ns, fa.base);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = base } });
                const field_id = self.language.fieldIdForName(fa.field);
                try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
                return try self.bindValue();
            },
            .dot_field_access => |dfa| {
                const field_id = self.language.fieldIdForName(dfa.field);
                try self.instruction_builder.emit(.{ .trv = .{ .field = field_id } });
                return try self.bindValue();
            },
            .identity => {
                return .{ .current = .value };
            },
            .node_selector => |node_selector| {
                const kind_id = self.language.idForNodeKind(node_selector.node_type, true);
                const bool_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .rel = .{
                    .relation = .equals,
                    .a = .{ .current = .kind },
                    .b = .{ .literal = .{ .kind_id = kind_id } },
                    .dest = bool_tmp,
                } });
                const skip_label = self.instruction_builder.createLabel();
                try self.instruction_builder.emitJumpCnd(.{ .variable_id = bool_tmp }, skip_label, false);
                try self.instruction_builder.emit(.halt);
                try self.instruction_builder.markLabel(skip_label);
                return try self.bindValue();
            },
            .object_literal => |obj| {
                const FieldSource = struct { key: []const u8, source: ir.ValueSource };
                var sources = try self.allocator.alloc(FieldSource, obj.fields.len);
                defer self.allocator.free(sources);

                const input_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = input_tmp, .source = .{ .current = .value } } });

                for (obj.fields, 0..) |field, i| {
                    switch (field) {
                        .variable => |variable| {
                            const var_id = self.variables.resolve(ns, variable.name) orelse
                                return error.InvalidVariableReference;
                            sources[i] = .{
                                .key = try self.addString(variable.name),
                                .source = .{ .variable_id = var_id },
                            };
                        },
                        .key_value => |kv| {
                            try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = input_tmp } } });
                            const vs = try self.compileExpression(ns, kv.value);
                            const field_tmp = self.variables.allocateAnonymous();
                            try self.instruction_builder.emit(.{ .asn = .{ .variable_id = field_tmp, .source = vs } });
                            sources[i] = .{
                                .key = try self.addString(kv.key),
                                .source = .{ .variable_id = field_tmp },
                            };
                        },
                    }
                }

                const resume_label = self.instruction_builder.createLabel();
                const anon_var = self.variables.allocateAnonymous();
                try self.instruction_builder.emitProbe(.{
                    .aggregate = .{ .variable = anon_var, .kind = .record },
                }, resume_label);

                for (sources) |fs| {
                    try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .literal = .{ .string = fs.key } } } });
                    try self.instruction_builder.emit(.{ .yield = .{ .source = fs.source } });
                }
                try self.instruction_builder.emit(.halt);
                try self.instruction_builder.markLabel(resume_label);
                return .{ .variable_id = anon_var };
            },
            .array_literal => |arr| return try self.compileListValue(ns, arr.elements),
            .tuple_literal => |tup| return try self.compileListValue(ns, tup.elements),
            .parenthesized => |p| return try self.compileExpression(ns, p.*),
            .collect_expression => |p| {
                const resume_label = self.instruction_builder.createLabel();
                const anon_var = self.variables.allocateAnonymous();
                try self.instruction_builder.emitProbe(.{
                    .aggregate = .{ .variable = anon_var, .kind = .list },
                }, resume_label);
                const pv = try self.compileExpression(ns, p.*);
                try self.instruction_builder.emit(.{ .yield = .{ .source = pv } });
                try self.instruction_builder.emit(.halt);
                try self.instruction_builder.markLabel(resume_label);
                return .{ .variable_id = anon_var };
            },
            .pipe_expression => |pe| {
                const lv = try self.compileExpression(ns, pe.left);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = lv } });
                return self.compileExpression(ns, pe.right);
            },
            .union_expression => |ue| {
                const left_label = self.instruction_builder.createLabel();
                const right_label = self.instruction_builder.createLabel();
                const end_label = self.instruction_builder.createLabel();

                try self.instruction_builder.emitAlt(left_label, right_label);
                const vs = try self.bindValue();
                try self.instruction_builder.emitJump(end_label);

                try self.instruction_builder.markLabel(left_label);
                const lv = try self.compileExpression(ns, ue.left);
                try self.instruction_builder.emit(.{ .yield = .{ .source = lv } });
                try self.instruction_builder.emit(.halt);

                try self.instruction_builder.markLabel(right_label);
                const rv = try self.compileExpression(ns, ue.right);
                try self.instruction_builder.emit(.{ .yield = .{ .source = rv } });
                try self.instruction_builder.emit(.halt);

                try self.instruction_builder.markLabel(end_label);
                return vs;
            },
            .child_navigation => |cn| {
                const parent = try self.compileExpression(ns, cn.parent);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = parent } });
                try self.instruction_builder.emit(.{ .trv = .{ .child = {} } });
                const cv = try self.compileExpression(ns, cn.child);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = cv } });
                return try self.bindValue();
            },
            .descendant_navigation => |dn| {
                const parent = try self.compileExpression(ns, dn.parent);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = parent } });
                try self.instruction_builder.emit(.{ .trv = .{ .descendant = {} } });
                const dv = try self.compileExpression(ns, dn.descendant);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = dv } });
                return try self.bindValue();
            },
            .comparison => |comparison| {
                const input_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = input_tmp, .source = .{ .current = .value } } });
                const left_vs = try self.compileExpression(ns, comparison.left);
                const left_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = left_tmp, .source = left_vs } });
                const left_source: ir.ValueSource = .{ .variable_id = left_tmp };
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = input_tmp } } });
                const right_source = try self.compileExpression(ns, comparison.right);
                const bool_tmp = self.variables.allocateAnonymous();

                switch (comparison.operator) {
                    .eq => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .equals, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return .{ .variable_id = bool_tmp };
                    },
                    .ne => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .equals, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return try self.compileNegateValue(.{ .variable_id = bool_tmp });
                    },
                    .regex_match => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .like, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return .{ .variable_id = bool_tmp };
                    },
                    .regex_not_match => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .like, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return try self.compileNegateValue(.{ .variable_id = bool_tmp });
                    },
                    .lt => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .lt, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return .{ .variable_id = bool_tmp };
                    },
                    .gt => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .gt, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return .{ .variable_id = bool_tmp };
                    },
                    .lte => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .gt, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return try self.compileNegateValue(.{ .variable_id = bool_tmp });
                    },
                    .gte => {
                        try self.instruction_builder.emit(.{ .rel = .{ .relation = .lt, .a = left_source, .b = right_source, .dest = bool_tmp } });
                        return try self.compileNegateValue(.{ .variable_id = bool_tmp });
                    },
                }
            },
            .is_null => |is_null| {
                const probe_resume_label = self.instruction_builder.createLabel();

                const probe_data: ir.ProbeData = if (is_null.negated) .exists else .nexists;
                try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

                _ = try self.compileExpression(ns, is_null.expression);
                try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .current = .value } } });
                try self.instruction_builder.emit(.halt);

                try self.instruction_builder.markLabel(probe_resume_label);
                return .{ .literal = .{ .bool = true } };
            },
            .logical_and => |la| {
                const result_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = .{ .literal = .{ .bool = false } } } });
                const input_tmp = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = input_tmp, .source = .{ .current = .value } } });
                const end_label = self.instruction_builder.createLabel();
                const left_vs = try self.compileExpression(ns, la.left);
                try self.instruction_builder.emitJumpCnd(left_vs, end_label, true);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = input_tmp } } });
                const right_vs = try self.compileExpression(ns, la.right);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = right_vs } });
                try self.instruction_builder.markLabel(end_label);
                return .{ .variable_id = result_tmp };
            },
            .logical_or => |lo| {
                const result_tmp = self.variables.allocateAnonymous();
                const saved_node = self.variables.allocateAnonymous();
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = saved_node, .source = .{ .current = .value } } });
                const true_label = self.instruction_builder.createLabel();
                const end_label = self.instruction_builder.createLabel();
                const left_vs = try self.compileExpression(ns, lo.left);
                try self.instruction_builder.emitJumpCnd(left_vs, true_label, false);
                try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = saved_node } } });
                const right_vs = try self.compileExpression(ns, lo.right);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = right_vs } });
                try self.instruction_builder.emitJump(end_label);
                try self.instruction_builder.markLabel(true_label);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = left_vs } });
                try self.instruction_builder.markLabel(end_label);
                return .{ .variable_id = result_tmp };
            },
            .logical_not => |ln| {
                // TODO: Figure out how to unify the model such that this "special" case isn't necessary
                if (ln.predicate == .function_call and
                    (std.mem.eql(u8, ln.predicate.function_call.name, "any") or
                        std.mem.eql(u8, ln.predicate.function_call.name, "all")))
                {
                    try self.compileBuiltinQuantified(ns, ln.predicate.function_call, true);
                    return .{ .literal = .{ .bool = true } };
                }
                const inner_vs = try self.compileExpression(ns, ln.predicate);
                return try self.compileNegateValue(inner_vs);
            },
            .bind_expression => |be| {
                const owned_name = try self.addString(be.variable.name);
                const var_id = try self.variables.declare(ns, owned_name);
                const vs = try self.compileExpression(ns, be.expression);
                try self.instruction_builder.emit(.{ .asn = .{ .variable_id = var_id, .source = vs } });
                return .{ .variable_id = var_id };
            },
        }
    }

    fn compileBuiltinQuantified(
        self: *Compiler,
        ns: *Namespace,
        fc: ast.FunctionCall,
        negated: bool,
    ) CompilerError!void {
        if (fc.arguments.len != 2) return error.InvalidGuardExpression;
        const is_all = std.mem.eql(u8, fc.name, "all");
        const body_negated = is_all;
        const probe_negated = negated != body_negated;

        const probe_resume_label = self.instruction_builder.createLabel();

        const probe_data: ir.ProbeData = if (probe_negated) .nexists else .exists;
        try self.instruction_builder.emitProbe(probe_data, probe_resume_label);

        const source_vs = try self.compileExpression(ns, fc.arguments[0]);
        try self.instruction_builder.emit(.{ .trv = .{ .value_source = source_vs } });

        const inner_failure_label = self.instruction_builder.createLabel();
        const pred_vs = try self.compileExpression(ns, fc.arguments[1]);
        if (body_negated) {
            try self.instruction_builder.emitJumpCnd(pred_vs, inner_failure_label, true);
            try self.instruction_builder.emit(.halt);
            try self.instruction_builder.markLabel(inner_failure_label);
            try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .current = .value } } });
        } else {
            try self.instruction_builder.emitJumpCnd(pred_vs, inner_failure_label, true);
            try self.instruction_builder.emit(.{ .yield = .{ .source = .{ .current = .value } } });
            try self.instruction_builder.markLabel(inner_failure_label);
            try self.instruction_builder.emit(.halt);
        }

        try self.instruction_builder.markLabel(probe_resume_label);
    }

    /// Emits instructions that flip a boolean, storing the result in a new
    /// variable.
    ///
    /// This is a HACK and legitimately has performance implications that stems
    /// from the fact that there's no runtime-native way to negate a boolean
    /// currently.
    ///
    /// I'm consciously deciding not to change the runtime API until a clearer
    /// pattern emerges for operations on variables.
    ///
    /// Precondition:
    /// - vs refers to a boolean typed value
    ///
    fn compileNegateValue(self: *Compiler, vs: ir.ValueSource) CompilerError!ir.ValueSource {
        const result_tmp = self.variables.allocateAnonymous();
        const true_label = self.instruction_builder.createLabel();
        const end_label = self.instruction_builder.createLabel();
        try self.instruction_builder.emitJumpCnd(vs, true_label, false);
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = .{ .literal = .{ .bool = true } } } });
        try self.instruction_builder.emitJump(end_label);
        try self.instruction_builder.markLabel(true_label);
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = result_tmp, .source = .{ .literal = .{ .bool = false } } } });
        try self.instruction_builder.markLabel(end_label);
        return .{ .variable_id = result_tmp };
    }

    fn compileBuiltinSelect(self: *Compiler, ns: *Namespace, fc: ast.FunctionCall) CompilerError!ir.ValueSource {
        if (fc.arguments.len != 1) return error.InvalidGuardExpression;
        const saved_node = self.variables.allocateAnonymous();
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = saved_node, .source = .{ .current = .value } } });
        const vs = try self.compileExpression(ns, fc.arguments[0]);
        try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = saved_node } } });
        const end_label = self.instruction_builder.createLabel();
        try self.instruction_builder.emitJumpCnd(vs, end_label, false);
        try self.instruction_builder.emit(.halt);
        try self.instruction_builder.markLabel(end_label);
        return .{ .current = .value };
    }

    fn compileBuiltinUnnest(self: *Compiler, ns: *Namespace, fc: ast.FunctionCall) CompilerError!ir.ValueSource {
        if (fc.arguments.len != 1) return error.InvalidArguments;
        var arg = fc.arguments[0];
        while (arg == .parenthesized) arg = arg.parenthesized.*;
        const uv = try self.compileExpression(ns, arg);
        try self.instruction_builder.emit(.{ .trv = .{ .elements = uv } });
        return try self.bindValue();
    }

    fn compileListValue(self: *Compiler, ns: *Namespace, elements: []const ast.Expression) CompilerError!ir.ValueSource {
        const input_tmp = self.variables.allocateAnonymous();
        try self.instruction_builder.emit(.{ .asn = .{ .variable_id = input_tmp, .source = .{ .current = .value } } });

        const resume_label = self.instruction_builder.createLabel();
        const anon_var = self.variables.allocateAnonymous();
        try self.instruction_builder.emitProbe(.{
            .aggregate = .{ .variable = anon_var, .kind = .list },
        }, resume_label);

        for (elements) |elem| {
            try self.instruction_builder.emit(.{ .trv = .{ .value_source = .{ .variable_id = input_tmp } } });
            const vs = try self.compileExpression(ns, elem);
            try self.instruction_builder.emit(.{ .yield = .{ .source = vs } });
        }
        try self.instruction_builder.emit(.halt);
        try self.instruction_builder.markLabel(resume_label);
        return .{ .variable_id = anon_var };
    }
};
