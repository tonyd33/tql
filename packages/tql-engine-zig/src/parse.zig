//! Tree-sitter tree -> the typed CST in `cst.zig`.
//!
//! The walk is total: it never fails on the first bad node. Every `ERROR` and
//! `MISSING` node in the tree becomes a `parse` diagnostic, and the tree built
//! around it is whatever could still be recovered. Callers decide what to do
//! with a partial tree by asking the sink, not by catching an error.

const std = @import("std");
const ts = @import("tree-sitter");
const cst = @import("lang/cst.zig");
const string_literal = @import("lang/string_literal.zig");
const diagnostic = @import("diagnostic.zig");

const Span = diagnostic.Span;
const Sink = diagnostic.Sink;

extern fn tree_sitter_tql() *ts.Language;

/// A parsed source file and the diagnostics produced building it.
pub const ParseResult = struct {
    /// Allocated in `arena`, and freed with it.
    source_file: cst.SourceFile,
    diagnostics: []diagnostic.Diagnostic,
    allocator: std.mem.Allocator,
    /// Held by pointer: moving an `ArenaAllocator` struct dangles every
    /// allocation made through it.
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        for (self.diagnostics) |d| d.deinit(self.allocator);
        self.allocator.free(self.diagnostics);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn hasErrors(self: *const ParseResult) bool {
        return self.diagnostics.len > 0;
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,

    pub fn init(allocator: std.mem.Allocator) !Parser {
        const ts_parser = ts.Parser.create();
        errdefer ts_parser.destroy();

        try ts_parser.setLanguage(tree_sitter_tql());

        return Parser{ .allocator = allocator, .ts_parser = ts_parser };
    }

    pub fn deinit(self: *Parser) void {
        self.ts_parser.destroy();
    }

    /// Parses `source`, collecting every syntax error rather than stopping at
    /// the first. Caller owns the result.
    pub fn parseCollecting(self: *Parser, source: []const u8) !ParseResult {
        const tree = self.ts_parser.parseString(source, null) orelse
            return error.ParseFailed;
        defer tree.destroy();

        var sink = Sink.init(self.allocator);
        errdefer sink.deinit();

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = .init(self.allocator);
        errdefer arena.deinit();

        const root = tree.rootNode();
        try collectSyntaxErrors(root, &sink);

        var walker: Walker = .{ .allocator = arena.allocator(), .source = source, .sink = &sink };
        const source_file = try walker.sourceFile(root);

        return .{
            .source_file = source_file,
            .diagnostics = try sink.toOwnedSlice(),
            .allocator = self.allocator,
            .arena = arena,
        };
    }
};

fn spanOf(node: ts.Node) Span {
    const start = node.startPoint();
    const end = node.endPoint();
    return .{
        .start_byte = @intCast(node.startByte()),
        .end_byte = @intCast(node.endByte()),
        .start_point = .{ .row = @intCast(start.row), .column = @intCast(start.column) },
        .end_point = .{ .row = @intCast(end.row), .column = @intCast(end.column) },
    };
}

fn textOf(node: ts.Node, source: []const u8) []const u8 {
    return source[node.startByte()..node.endByte()];
}

/// Walks the whole tree reporting `ERROR` and `MISSING` nodes.
///
/// Done in one pass up front rather than during construction so that the order
/// of diagnostics follows the source, not the order the builder happens to
/// visit children in. A fixture asserting several diagnostics asserts them in
/// source order.
fn collectSyntaxErrors(node: ts.Node, sink: *Sink) !void {
    if (node.isError()) {
        try sink.report(.parse, spanOf(node), "syntax error", .{});
        // Children of an ERROR node are fragments of whatever the parser could
        // still shift. Reporting them too would turn one defect into a cascade.
        return;
    }
    if (node.isMissing()) {
        try sink.report(
            .parse,
            spanOf(node),
            "missing {s}",
            .{node.grammarKind()},
        );
        return;
    }
    if (!node.hasError()) return;

    var cursor = node.walk();
    defer cursor.destroy();
    if (!cursor.gotoFirstChild()) return;
    while (true) {
        try collectSyntaxErrors(cursor.node(), sink);
        if (!cursor.gotoNextSibling()) break;
    }
}

/// Builds the CST. Nothing it allocates is freed individually: `allocator` is
/// the result's arena.
const Walker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    sink: *Sink,

    fn dupe(self: *Walker, node: ts.Node) ![]const u8 {
        return self.allocator.dupe(u8, textOf(node, self.source));
    }

    fn boxed(self: *Walker, value: anytype) !*@TypeOf(value) {
        const ptr = try self.allocator.create(@TypeOf(value));
        ptr.* = value;
        return ptr;
    }

    /// A node the grammar guarantees but the tree lacks, because recovery ate
    /// it. Reported rather than propagated so the walk can continue.
    fn missingField(self: *Walker, node: ts.Node, field: []const u8) !void {
        try self.sink.report(
            .parse,
            spanOf(node),
            "expected {s} in {s}",
            .{ field, node.grammarKind() },
        );
    }

    fn sourceFile(self: *Walker, node: ts.Node) !cst.SourceFile {
        var declarations: std.ArrayList(cst.Declaration) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const kind = child.grammarKind();
                if (std.mem.eql(u8, kind, "signature")) {
                    if (try self.signature(child)) |s| {
                        try declarations.append(self.allocator, .{ .signature = s });
                    }
                } else if (std.mem.eql(u8, kind, "definition")) {
                    if (try self.definition(child)) |d| {
                        try declarations.append(self.allocator, .{ .definition = d });
                    }
                } else if (std.mem.eql(u8, kind, "type_declaration")) {
                    if (try self.typeDeclaration(child)) |t| {
                        try declarations.append(self.allocator, .{ .type_declaration = t });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return .{
            .declarations = try declarations.toOwnedSlice(self.allocator),
            .span = spanOf(node),
        };
    }

    fn signature(self: *Walker, node: ts.Node) !?cst.Signature {
        const name_node = node.childByFieldName("name") orelse {
            try self.missingField(node, "name");
            return null;
        };
        const type_node = node.childByFieldName("type") orelse {
            try self.missingField(node, "type");
            return null;
        };
        const name = try self.dupe(name_node);
        const constraints = if (node.childByFieldName("context")) |c|
            try self.context(c) orelse return null
        else
            &.{};
        const ty = try self.typeExpr(type_node) orelse return null;
        return .{ .name = name, .context = constraints, .type = ty, .span = spanOf(node) };
    }

    fn context(self: *Walker, node: ts.Node) !?[]const cst.ClassConstraint {
        var collected: std.ArrayList(cst.ClassConstraint) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "class_constraint")) {
                    const class_node = child.childByFieldName("class") orelse {
                        try self.missingField(child, "class");
                        return null;
                    };
                    const variable_node = child.childByFieldName("variable") orelse {
                        try self.missingField(child, "variable");
                        return null;
                    };
                    try collected.append(self.allocator, .{
                        .class = try self.dupe(class_node),
                        .variable = try self.dupe(variable_node),
                        .span = spanOf(child),
                    });
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return try collected.toOwnedSlice(self.allocator);
    }

    fn definition(self: *Walker, node: ts.Node) !?cst.Definition {
        const name_node = node.childByFieldName("name") orelse {
            try self.missingField(node, "name");
            return null;
        };
        const name = try self.dupe(name_node);
        const params = try self.parameters(node);

        const body_node = node.childByFieldName("body") orelse {
            try self.missingField(node, "body");
            return null;
        };
        const body = try self.expression(body_node) orelse return null;

        return .{
            .name = name,
            .parameters = params,
            .body = body,
            .span = spanOf(node),
        };
    }

    /// Every `parameter:`-tagged child of `node`, in order.
    fn parameters(self: *Walker, node: ts.Node) ![]const cst.Parameter {
        var collected: std.ArrayList(cst.Parameter) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "parameter")) {
                        const child = cursor.node();
                        try collected.append(self.allocator, .{
                            .name = try self.dupe(child),
                            .span = spanOf(child),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return collected.toOwnedSlice(self.allocator);
    }

    fn binding(self: *Walker, node: ts.Node) !?cst.Binding {
        const name_node = node.childByFieldName("name") orelse {
            try self.missingField(node, "name");
            return null;
        };
        const name = try self.dupe(name_node);
        const params = try self.parameters(node);

        const value_node = node.childByFieldName("value") orelse {
            try self.missingField(node, "value");
            return null;
        };
        const value = try self.expression(value_node) orelse return null;

        return .{
            .name = name,
            .parameters = params,
            .value = value,
            .span = spanOf(node),
        };
    }

    /// The bindings of a `binding_group`, or the single binding of an unbraced
    /// `do`-local `let`.
    fn bindings(self: *Walker, node: ts.Node) ![]const cst.Binding {
        var collected: std.ArrayList(cst.Binding) = .empty;

        if (std.mem.eql(u8, node.grammarKind(), "binding")) {
            if (try self.binding(node)) |b| try collected.append(self.allocator, b);
            return collected.toOwnedSlice(self.allocator);
        }

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "binding")) {
                    if (try self.binding(child)) |b| try collected.append(self.allocator, b);
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return collected.toOwnedSlice(self.allocator);
    }

    fn expression(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Expression {
        const span = spanOf(node);
        const kind = node.grammarKind();

        if (std.mem.eql(u8, kind, "identity")) {
            return .{ .kind = .identity, .span = span };
        }
        if (std.mem.eql(u8, kind, "identifier")) {
            return .{ .kind = .{ .name = try self.dupe(node) }, .span = span };
        }
        if (std.mem.eql(u8, kind, "kind")) {
            // The lexeme includes the leading `:`, which is punctuation.
            const text = textOf(node, self.source);
            const name = try self.allocator.dupe(u8, text[1..]);
            return .{ .kind = .{ .kind_test = name }, .span = span };
        }
        if (std.mem.eql(u8, kind, "number")) {
            const text = textOf(node, self.source);
            const value = std.fmt.parseInt(i64, text, 10) catch {
                try self.sink.report(.parse, span, "integer literal out of range", .{});
                return null;
            };
            return .{ .kind = .{ .number = value }, .span = span };
        }
        if (std.mem.eql(u8, kind, "boolean")) {
            const text = textOf(node, self.source);
            return .{
                .kind = .{ .boolean = std.mem.eql(u8, text, "true") },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "string")) {
            const text = textOf(node, self.source);
            const body = if (text.len >= 2) text[1 .. text.len - 1] else text;
            switch (try string_literal.decode(self.allocator, body)) {
                .bytes => |bytes| return .{ .kind = .{ .string = bytes }, .span = span },
                .invalid_escape => |at| {
                    try self.sink.report(
                        .parse,
                        span,
                        "`{s}` is not an escape; write `\\\\` for a backslash",
                        .{body[at .. at + 2]},
                    );
                    return null;
                },
            }
        }
        if (std.mem.eql(u8, kind, "regex")) {
            // `r"..."`: two leading bytes, one trailing.
            const text = textOf(node, self.source);
            const body = if (text.len >= 3) text[2 .. text.len - 1] else text;
            return .{
                .kind = .{ .regex = try self.allocator.dupe(u8, body) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "field_access")) {
            return self.fieldAccess(node, span);
        }
        if (std.mem.eql(u8, kind, "leading_field")) {
            return self.leadingField(node, span);
        }
        if (std.mem.eql(u8, kind, "application") or std.mem.eql(u8, kind, "dollar_application")) {
            return self.application(node, span);
        }
        if (std.mem.eql(u8, kind, "logical_not")) {
            return self.notExpr(node, span);
        }
        if (std.mem.eql(u8, kind, "if_expression")) {
            return self.ifExpr(node, span);
        }
        if (std.mem.eql(u8, kind, "case_expression")) {
            return self.caseExpr(node, span);
        }
        if (std.mem.eql(u8, kind, "type_identifier")) {
            return cst.Expression{
                .kind = .{ .constructor = try self.dupe(node) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "lambda")) {
            return self.lambda(node, span);
        }
        if (std.mem.eql(u8, kind, "let_expression")) {
            return self.letExpr(node, span);
        }
        if (std.mem.eql(u8, kind, "do_expression")) {
            return self.doExpr(node, span);
        }
        if (std.mem.eql(u8, kind, "list")) {
            return self.list(node, span);
        }
        if (std.mem.eql(u8, kind, "record")) {
            return self.record(node, span);
        }
        if (std.mem.eql(u8, kind, "parenthesized")) {
            const inner_node = node.namedChild(0) orelse {
                try self.missingField(node, "expression");
                return null;
            };
            const inner = try self.expression(inner_node) orelse return null;
            return .{
                .kind = .{ .parenthesized = try self.boxed(inner) },
                .span = span,
            };
        }

        if (binaryOperatorOf(kind)) |_| {
            return self.binary(node, span);
        }

        // An ERROR or MISSING node, already reported by `collectSyntaxErrors`.
        if (node.isError() or node.isMissing()) return null;

        try self.sink.report(.parse, span, "unexpected {s}", .{kind});
        return null;
    }

    fn fieldAccess(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const record_node = node.childByFieldName("record") orelse {
            try self.missingField(node, "record");
            return null;
        };
        const field_node = node.childByFieldName("field") orelse {
            try self.missingField(node, "field");
            return null;
        };
        const record_expr = try self.expression(record_node) orelse return null;
        const field = try self.dupe(field_node);
        return .{
            .kind = .{ .field_access = try self.boxed(cst.FieldAccess{
                .record = record_expr,
                .field = field,
            }) },
            .span = span,
        };
    }

    fn leadingField(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const field_node = node.childByFieldName("field") orelse {
            try self.missingField(node, "field");
            return null;
        };
        const field = try self.dupe(field_node);
        return .{
            .kind = .{ .field_access = try self.boxed(cst.FieldAccess{
                .record = null,
                .field = field,
            }) },
            .span = span,
        };
    }

    fn application(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const fn_node = node.childByFieldName("function") orelse {
            try self.missingField(node, "function");
            return null;
        };
        const arg_node = node.childByFieldName("argument") orelse {
            try self.missingField(node, "argument");
            return null;
        };
        const function = try self.expression(fn_node) orelse return null;
        const argument = try self.expression(arg_node) orelse return null;
        return .{
            .kind = .{ .apply = try self.boxed(cst.Apply{
                .function = function,
                .argument = argument,
            }) },
            .span = span,
        };
    }

    fn binary(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const left_node = node.childByFieldName("left") orelse {
            try self.missingField(node, "left");
            return null;
        };
        const right_node = node.childByFieldName("right") orelse {
            try self.missingField(node, "right");
            return null;
        };

        const operator = if (node.childByFieldName("operator")) |op_node|
            operatorFromSpelling(textOf(op_node, self.source)) orelse {
                try self.sink.report(.parse, span, "unknown operator", .{});
                return null;
            }
        else
            // `union`, `pipe`, `logical_and` and `logical_or` spell their
            // operator in the rule name rather than an `operator:` field.
            binaryOperatorOf(node.grammarKind()) orelse {
                try self.missingField(node, "operator");
                return null;
            };

        const left = try self.expression(left_node) orelse return null;
        const right = try self.expression(right_node) orelse return null;
        return .{
            .kind = .{ .binary = try self.boxed(cst.Binary{
                .operator = operator,
                .left = left,
                .right = right,
            }) },
            .span = span,
        };
    }

    fn notExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const operand_node = node.childByFieldName("operand") orelse {
            try self.missingField(node, "operand");
            return null;
        };
        const operand = try self.expression(operand_node) orelse return null;
        return .{
            .kind = .{ .not = try self.boxed(cst.Not{ .operand = operand }) },
            .span = span,
        };
    }

    fn typeDeclaration(self: *Walker, node: ts.Node) !?cst.TypeDeclaration {
        const name_node = node.childByFieldName("name") orelse {
            try self.missingField(node, "name");
            return null;
        };
        const name = try self.dupe(name_node);
        var params: std.ArrayList(cst.Identifier) = .empty;
        var constructors: std.ArrayList(cst.ConstructorDeclaration) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    const child = cursor.node();
                    if (std.mem.eql(u8, field, "parameter")) {
                        try params.append(self.allocator, try self.dupe(child));
                    } else if (std.mem.eql(u8, field, "constructor")) {
                        if (try self.constructorDeclaration(child)) |c| {
                            try constructors.append(self.allocator, c);
                        } else return null;
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return .{
            .name = name,
            .parameters = try params.toOwnedSlice(self.allocator),
            .constructors = try constructors.toOwnedSlice(self.allocator),
            .span = spanOf(node),
        };
    }

    fn constructorDeclaration(self: *Walker, node: ts.Node) !?cst.ConstructorDeclaration {
        const name_node = node.childByFieldName("name") orelse {
            try self.missingField(node, "name");
            return null;
        };
        const name = try self.dupe(name_node);
        var fields: std.ArrayList(cst.Type) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "field")) {
                        const t = try self.typeExpr(cursor.node()) orelse return null;
                        try fields.append(self.allocator, t);
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .span = spanOf(node),
        };
    }

    fn caseExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const scrutinee_node = node.childByFieldName("scrutinee") orelse {
            try self.missingField(node, "scrutinee");
            return null;
        };
        const scrutinee = try self.expression(scrutinee_node) orelse return null;
        var alternatives: std.ArrayList(cst.Case.Alternative) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "case_alternative")) {
                    if (try self.caseAlternative(child)) |a| {
                        try alternatives.append(self.allocator, a);
                    } else return null;
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return .{
            .kind = .{ .case = try self.boxed(cst.Case{
                .scrutinee = scrutinee,
                .alternatives = try alternatives.toOwnedSlice(self.allocator),
            }) },
            .span = span,
        };
    }

    fn caseAlternative(self: *Walker, node: ts.Node) !?cst.Case.Alternative {
        const name_node = node.childByFieldName("constructor") orelse {
            try self.missingField(node, "constructor");
            return null;
        };
        const body_node = node.childByFieldName("body") orelse {
            try self.missingField(node, "body");
            return null;
        };
        const constructor = try self.dupe(name_node);
        var binders: std.ArrayList(cst.Parameter) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "binder")) {
                        const child = cursor.node();
                        try binders.append(self.allocator, .{
                            .name = try self.dupe(child),
                            .span = spanOf(child),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        const body = try self.expression(body_node) orelse return null;
        return .{
            .constructor = constructor,
            .binders = try binders.toOwnedSlice(self.allocator),
            .body = body,
            .span = spanOf(node),
        };
    }

    fn ifExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const cond_node = node.childByFieldName("condition") orelse {
            try self.missingField(node, "condition");
            return null;
        };
        const then_node = node.childByFieldName("consequence") orelse {
            try self.missingField(node, "consequence");
            return null;
        };
        const else_node = node.childByFieldName("alternative") orelse {
            try self.missingField(node, "alternative");
            return null;
        };
        const condition = try self.expression(cond_node) orelse return null;
        const consequence = try self.expression(then_node) orelse return null;
        const alternative = try self.expression(else_node) orelse return null;
        return .{
            .kind = .{ .@"if" = try self.boxed(cst.If{
                .condition = condition,
                .consequence = consequence,
                .alternative = alternative,
            }) },
            .span = span,
        };
    }

    fn lambda(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const params = try self.parameters(node);
        const body_node = node.childByFieldName("body") orelse {
            try self.missingField(node, "body");
            return null;
        };
        const body = try self.expression(body_node) orelse return null;
        return .{
            .kind = .{ .lambda = try self.boxed(cst.Lambda{
                .parameters = params,
                .body = body,
            }) },
            .span = span,
        };
    }

    fn letExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const group_node = node.childByFieldName("bindings") orelse {
            try self.missingField(node, "bindings");
            return null;
        };
        const binding_list = try self.bindings(group_node);
        const body_node = node.childByFieldName("body") orelse {
            try self.missingField(node, "body");
            return null;
        };
        const body = try self.expression(body_node) orelse return null;
        return .{
            .kind = .{ .let = try self.boxed(cst.Let{
                .bindings = binding_list,
                .body = body,
            }) },
            .span = span,
        };
    }

    fn doExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        var statements: std.ArrayList(cst.Statement) = .empty;

        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            const child = node.namedChild(i).?;
            if (child.isExtra()) continue;
            const kind = child.grammarKind();
            if (std.mem.eql(u8, kind, "bind_statement")) {
                const name_node = child.childByFieldName("name") orelse {
                    try self.missingField(child, "name");
                    continue;
                };
                const value_node = child.childByFieldName("value") orelse {
                    try self.missingField(child, "value");
                    continue;
                };
                const name = try self.dupe(name_node);
                if (try self.expression(value_node)) |value| {
                    try statements.append(self.allocator, .{ .bind = .{
                        .name = name,
                        .value = value,
                        .span = spanOf(child),
                    } });
                }
            } else if (std.mem.eql(u8, kind, "let_statement")) {
                const group_node = child.childByFieldName("bindings") orelse {
                    try self.missingField(child, "bindings");
                    continue;
                };
                try statements.append(self.allocator, .{ .let = .{
                    .bindings = try self.bindings(group_node),
                    .span = spanOf(child),
                } });
            } else if (try self.expression(child)) |value| {
                try statements.append(self.allocator, .{ .expression = value });
            }
        }

        const last = statements.pop() orelse {
            try self.sink.report(.parse, span, "a do block must end in an expression", .{});
            return null;
        };
        const result = switch (last) {
            .expression => |e| e,
            .bind => |b| {
                try self.sink.report(.parse, b.span, "a do block must end in an expression, not a bind statement", .{});
                return null;
            },
            .let => |l| {
                try self.sink.report(.parse, l.span, "a do block must end in an expression, not a let statement", .{});
                return null;
            },
        };

        return .{
            .kind = .{ .do = try self.boxed(cst.Do{
                .statements = try statements.toOwnedSlice(self.allocator),
                .result = result,
            }) },
            .span = span,
        };
    }

    fn list(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        var elements: std.ArrayList(cst.Expression) = .empty;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            const child = node.namedChild(i).?;
            if (child.isExtra()) continue;
            try elements.append(self.allocator, try self.expression(child) orelse return null);
        }
        return .{
            .kind = .{ .list = try elements.toOwnedSlice(self.allocator) },
            .span = span,
        };
    }

    fn record(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        var fields: std.ArrayList(cst.RecordField) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "record_field")) {
                    const name_node = child.childByFieldName("name") orelse {
                        try self.missingField(child, "name");
                        if (!cursor.gotoNextSibling()) break;
                        continue;
                    };
                    const value_node = child.childByFieldName("value") orelse {
                        try self.missingField(child, "value");
                        if (!cursor.gotoNextSibling()) break;
                        continue;
                    };
                    const name = try self.dupe(name_node);
                    if (try self.expression(value_node)) |value| {
                        try fields.append(self.allocator, .{
                            .name = name,
                            .value = value,
                            .span = spanOf(child),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return cst.Expression{
            .kind = .{ .record = .{ .fields = try fields.toOwnedSlice(self.allocator) } },
            .span = span,
        };
    }

    fn typeApplication(self: *Walker, node: ts.Node, span: Span) (error{OutOfMemory})!?cst.Type {
        const name_node = node.childByFieldName("constructor") orelse {
            try self.missingField(node, "constructor");
            return null;
        };
        const constructor = try self.dupe(name_node);
        var arguments: std.ArrayList(cst.Type) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "argument")) {
                        const t = try self.typeExpr(cursor.node()) orelse return null;
                        try arguments.append(self.allocator, t);
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return cst.Type{
            .kind = .{ .application = try self.boxed(cst.TypeApplication{
                .constructor = constructor,
                .arguments = try arguments.toOwnedSlice(self.allocator),
            }) },
            .span = span,
        };
    }

    fn typeExpr(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Type {
        const span = spanOf(node);
        const kind = node.grammarKind();

        if (std.mem.eql(u8, kind, "type_identifier")) {
            return cst.Type{
                .kind = .{ .constructor = try self.dupe(node) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "type_application")) {
            return self.typeApplication(node, span);
        }
        if (std.mem.eql(u8, kind, "type_variable")) {
            return cst.Type{
                .kind = .{ .variable = try self.dupe(node) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "function_type")) {
            const from_node = node.childByFieldName("from") orelse {
                try self.missingField(node, "from");
                return null;
            };
            const to_node = node.childByFieldName("to") orelse {
                try self.missingField(node, "to");
                return null;
            };
            const from = try self.typeExpr(from_node) orelse return null;
            const to = try self.typeExpr(to_node) orelse return null;
            return cst.Type{
                .kind = .{ .function = try self.boxed(cst.FunctionType{
                    .from = from,
                    .to = to,
                }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "filter_type")) {
            const in_node = node.childByFieldName("input") orelse {
                try self.missingField(node, "input");
                return null;
            };
            const out_node = node.childByFieldName("output") orelse {
                try self.missingField(node, "output");
                return null;
            };
            const input = try self.typeExpr(in_node) orelse return null;
            const output = try self.typeExpr(out_node) orelse return null;
            return cst.Type{
                .kind = .{ .filter = try self.boxed(cst.FilterType{
                    .input = input,
                    .output = output,
                }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "list_type")) {
            const inner_node = node.namedChild(0) orelse {
                try self.missingField(node, "element");
                return null;
            };
            const inner = try self.typeExpr(inner_node) orelse return null;
            return cst.Type{
                .kind = .{ .list = try self.boxed(inner) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "parenthesized_type")) {
            const inner_node = node.namedChild(0) orelse {
                try self.missingField(node, "type");
                return null;
            };
            const inner = try self.typeExpr(inner_node) orelse return null;
            return cst.Type{
                .kind = .{ .parenthesized = try self.boxed(inner) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "record_type")) {
            var fields: std.ArrayList(cst.TypeField) = .empty;

            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                while (true) {
                    const child = cursor.node();
                    if (std.mem.eql(u8, child.grammarKind(), "record_type_field")) {
                        const name_node = child.childByFieldName("name") orelse {
                            try self.missingField(child, "name");
                            if (!cursor.gotoNextSibling()) break;
                            continue;
                        };
                        const type_node = child.childByFieldName("type") orelse {
                            try self.missingField(child, "type");
                            if (!cursor.gotoNextSibling()) break;
                            continue;
                        };
                        const name = try self.dupe(name_node);
                        if (try self.typeExpr(type_node)) |ty| {
                            try fields.append(self.allocator, .{
                                .name = name,
                                .type = ty,
                                .span = spanOf(child),
                            });
                        }
                    }
                    if (!cursor.gotoNextSibling()) break;
                }
            }

            return cst.Type{
                .kind = .{ .record = try fields.toOwnedSlice(self.allocator) },
                .span = span,
            };
        }

        if (node.isError() or node.isMissing()) return null;

        try self.sink.report(.parse, span, "unexpected {s} in type", .{kind});
        return null;
    }
};

/// The operator a rule name implies, for rules that do not carry an
/// `operator:` field.
fn binaryOperatorOf(kind: []const u8) ?cst.BinaryOperator {
    if (std.mem.eql(u8, kind, "union")) return .stream_union;
    if (std.mem.eql(u8, kind, "pipe")) return .pipe;
    if (std.mem.eql(u8, kind, "logical_and")) return .@"and";
    if (std.mem.eql(u8, kind, "logical_or")) return .@"or";
    if (std.mem.eql(u8, kind, "comparison")) return .eq;
    if (std.mem.eql(u8, kind, "additive")) return .add;
    if (std.mem.eql(u8, kind, "multiplicative")) return .multiply;
    return null;
}

fn operatorFromSpelling(text: []const u8) ?cst.BinaryOperator {
    const table = [_]struct { []const u8, cst.BinaryOperator }{
        .{ "/", .divide },
        .{ "*", .multiply },
        .{ "%", .modulo },
        .{ "+", .add },
        .{ "-", .subtract },
        .{ "!=", .ne },
        .{ "<=", .lte },
        .{ ">=", .gte },
        .{ "=", .eq },
        .{ "<", .lt },
        .{ ">", .gt },
        .{ "!~", .not_match },
        .{ "~", .match },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectSexpr(source: []const u8, expected: []const u8) !void {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    var result = try parser.parseCollecting(source);
    defer result.deinit();

    try testing.expectEqual(0, result.diagnostics.len);

    const actual = try result.source_file.sexprAlloc(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "children compose with a kind test" {
    try expectSexpr(
        "main root = (children | is_kind :class_declaration) root;",
        "(source_file (define main (params root) " ++
            "(apply (paren (| children (apply is_kind (kind class_declaration)))) root)))",
    );
}

test "field access binds tighter than application" {
    try expectSexpr(
        "main = f x.name;",
        "(source_file (define main (params) (apply f (field x name))))",
    );
}

test "a leading field has no record" {
    try expectSexpr(
        "main = .name;",
        "(source_file (define main (params) (field . name)))",
    );
}

test "descendants compose with a kind test" {
    try expectSexpr(
        "main root = (descendants | is_kind :method_definition) root;",
        "(source_file (define main (params root) " ++
            "(apply (paren (| descendants (apply is_kind (kind method_definition)))) root)))",
    );
}

test "division is an ordinary arithmetic operator" {
    try expectSexpr(
        "main = 7 / 2;",
        "(source_file (define main (params) (/ 7 2)))",
    );
}

test "a bare axis is the wildcard navigation" {
    try expectSexpr(
        "main root = children root;",
        "(source_file (define main (params root) (apply children root)))",
    );
}

test "a let group with several bindings" {
    try expectSexpr(
        "main = let { a = 1; b = 2 } in a + b;",
        "(source_file (define main (params) " ++
            "(let ((bind a (params) 1) (bind b (params) 2)) (+ a b))))",
    );
}

test "a do block with a bind statement" {
    try expectSexpr(
        "main = do { c <- .; c.name };",
        "(source_file (define main (params) (do (<- c .) (field c name))))",
    );
}

test "a do block with an expression statement" {
    try expectSexpr(
        "main = do { c <- .; guard $ c = c; c };",
        "(source_file (define main (params) (do (<- c .) (>> (apply guard (= c c))) c)))",
    );
}

test "a do-local let statement" {
    try expectSexpr(
        "main = do { c <- .; let n = c.name; n };",
        "(source_file (define main (params) " ++
            "(do (<- c .) (let (bind n (params) (field c name))) n)))",
    );
}

test "a signature" {
    try expectSexpr(
        "main : Filter node string;",
        "(source_file (signature main (Filter node string)))",
    );
}

test "a function-typed signature" {
    try expectSexpr(
        "f : Filter node node -> Filter node string;",
        "(source_file (signature f (-> (Filter node node) (Filter node string))))",
    );
}

test "a signature with a context" {
    try expectSexpr(
        "f : (Eq a, Sized b) => a -> b -> Int;",
        "(source_file (signature f (=> (Eq a) (Sized b)) (-> a (-> b Int))))",
    );
}

test "a lambda with several parameters" {
    try expectSexpr(
        "main = \\x y -> x + y;",
        "(source_file (define main (params) (lambda (params x y) (+ x y))))",
    );
}

test "a record literal" {
    try expectSexpr(
        "main = { k = kind, t = text };",
        "(source_file (define main (params) (record (k kind) (t text))))",
    );
}

test "an empty list" {
    try expectSexpr(
        "main = [];",
        "(source_file (define main (params) (list)))",
    );
}

test "a list literal keeps its elements in order" {
    try expectSexpr(
        "main = [1, a | b, -- two\n c,];",
        "(source_file (define main (params) (list 1 (| a b) c)))",
    );
}

test "union is spelled <|>" {
    try expectSexpr(
        "main = a <|> b | c;",
        "(source_file (define main (params) (<|> a (| b c))))",
    );
}

test "dollar application is right-associative plain application" {
    try expectSexpr(
        "main = f $ g $ a <|> b;",
        "(source_file (define main (params) (apply f (apply g (<|> a b)))))",
    );
}

test "a definition with parameters" {
    try expectSexpr(
        "add x y = x + y;",
        "(source_file (define add (params x y) (+ x y)))",
    );
}

test "a comparison chain groups to the left" {
    try expectSexpr(
        "main = 1 < 2 < 3;",
        "(source_file (define main (params) (< (< 1 2) 3)))",
    );
}

test "spans are byte-accurate" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    var result = try parser.parseCollecting("main = 1 + 2;");
    defer result.deinit();

    const body = result.source_file.declarations[0].definition.body;
    try testing.expectEqual(7, body.span.start_byte);
    try testing.expectEqual(12, body.span.end_byte);
    try testing.expectEqual(0, body.span.start_point.row);
    try testing.expectEqual(7, body.span.start_point.column);
}

test "an unclosed group reports a missing token" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    var result = try parser.parseCollecting("main = (1 + 2;");
    defer result.deinit();

    try testing.expect(result.hasErrors());
    try testing.expectEqual(diagnostic.Category.parse, result.diagnostics[0].category);
}

test "a declaration dropped by recovery leaks nothing it had built" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    // Each literal is out of range, so the walk abandons the lambda, the case
    // alternative and the binding around it after building their heads.
    var result = try parser.parseCollecting(
        \\main p = \x y -> case x of { C a b -> 99999999999999999999999 };
        \\other = let { f q = 99999999999999999999999 } in \z -> 99999999999999999999999;
    );
    defer result.deinit();

    try testing.expectEqual(0, result.source_file.declarations.len);
    try testing.expectEqual(3, result.diagnostics.len);
    for (result.diagnostics) |d| {
        try testing.expectEqualStrings("integer literal out of range", d.message);
    }
}

test "an incomplete declaration spans the declaration" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    var result = try parser.parseCollecting("main =");
    defer result.deinit();

    try testing.expectEqual(1, result.diagnostics.len);
    const span = result.diagnostics[0].span;
    try testing.expectEqual(0, span.start_byte);
    try testing.expectEqual(6, span.end_byte);
}

test "several declarations parse independently" {
    try expectSexpr(
        "a = 1;\nb = 2;",
        "(source_file (define a (params) 1) (define b (params) 2))",
    );
}
