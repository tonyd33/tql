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
    /// the first. Every span in the result names `source_id`. Caller owns the
    /// result.
    pub fn parseCollecting(
        self: *Parser,
        source: []const u8,
        source_id: diagnostic.SourceId,
    ) !ParseResult {
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
        try collectSyntaxErrors(root, source_id, &sink);

        var walker: Walker = .{
            .allocator = arena.allocator(),
            .source = source,
            .source_id = source_id,
            .sink = &sink,
        };
        const source_file = try walker.sourceFile(root);

        return .{
            .source_file = source_file,
            .diagnostics = try sink.toOwnedSlice(),
            .allocator = self.allocator,
            .arena = arena,
        };
    }
};

fn spanOf(node: ts.Node, source_id: diagnostic.SourceId) Span {
    const start = node.startPoint();
    const end = node.endPoint();
    return .{
        .start_byte = @intCast(node.startByte()),
        .end_byte = @intCast(node.endByte()),
        .start_point = .{ .row = @intCast(start.row), .column = @intCast(start.column) },
        .end_point = .{ .row = @intCast(end.row), .column = @intCast(end.column) },
        .source = source_id,
    };
}

fn isConstructor(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "type_identifier") or std.mem.eql(u8, kind, "qualified_type_identifier");
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
fn collectSyntaxErrors(node: ts.Node, source_id: diagnostic.SourceId, sink: *Sink) !void {
    if (node.isError()) {
        try sink.report(.parse, spanOf(node, source_id), "syntax error", .{});
        // Children of an ERROR node are fragments of whatever the parser could
        // still shift. Reporting them too would turn one defect into a cascade.
        return;
    }
    if (node.isMissing()) {
        try sink.report(
            .parse,
            spanOf(node, source_id),
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
        try collectSyntaxErrors(cursor.node(), source_id, sink);
        if (!cursor.gotoNextSibling()) break;
    }
}

/// Builds the CST. Nothing it allocates is freed individually: `allocator` is
/// the result's arena.
const Walker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    source_id: diagnostic.SourceId,
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
            spanOf(node, self.source_id),
            "expected {s} in {s}",
            .{ field, node.grammarKind() },
        );
    }

    /// Returns `node`'s child in field `name`, or null after reporting it
    /// missing.
    fn requiredField(self: *Walker, node: ts.Node, name: []const u8) !?ts.Node {
        return node.childByFieldName(name) orelse {
            try self.missingField(node, name);
            return null;
        };
    }

    fn sourceFile(self: *Walker, node: ts.Node) !cst.SourceFile {
        var declarations: std.ArrayList(cst.Declaration) = .empty;
        var imports: std.ArrayList(cst.Import) = .empty;
        var header: ?cst.ModuleHeader = null;

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const kind = child.grammarKind();
                if (std.mem.eql(u8, kind, "module_header")) {
                    header = try self.moduleHeader(child);
                } else if (std.mem.eql(u8, kind, "import_declaration")) {
                    if (try self.importDeclaration(child)) |i| try imports.append(self.allocator, i);
                } else if (std.mem.eql(u8, kind, "signature")) {
                    if (try self.signature(child)) |s| {
                        try declarations.append(self.allocator, .{ .signature = s });
                    }
                } else if (std.mem.eql(u8, kind, "definition")) {
                    if (try self.definition(child)) |d| {
                        try declarations.append(self.allocator, .{ .definition = d });
                    }
                } else if (std.mem.eql(u8, kind, "data_declaration")) {
                    if (try self.dataDeclaration(child)) |t| {
                        try declarations.append(self.allocator, .{ .data_declaration = t });
                    }
                } else if (std.mem.eql(u8, kind, "type_alias")) {
                    if (try self.typeAlias(child)) |t| {
                        try declarations.append(self.allocator, .{ .type_alias = t });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return .{
            .header = header,
            .imports = try imports.toOwnedSlice(self.allocator),
            .declarations = try declarations.toOwnedSlice(self.allocator),
            .span = spanOf(node, self.source_id),
        };
    }

    fn moduleHeader(self: *Walker, node: ts.Node) !?cst.ModuleHeader {
        const name_node = try self.requiredField(node, "name") orelse return null;
        var grammars: std.ArrayList([]const u8) = .empty;
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "grammar")) try grammars.append(self.allocator, try self.dupe(cursor.node()));
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }
        return .{
            .name = try self.dupe(name_node),
            .exports = if (node.childByFieldName("exports")) |exports| .{ .only = try self.items(exports) } else .all,
            .grammars = if (grammars.items.len == 0) null else try grammars.toOwnedSlice(self.allocator),
            .span = spanOf(node, self.source_id),
        };
    }

    fn importDeclaration(self: *Walker, node: ts.Node) !?cst.Import {
        const module_node = try self.requiredField(node, "module") orelse return null;
        const selects: cst.Filter = if (node.childByFieldName("items")) |listed|
            .{ .only = try self.items(listed) }
        else if (node.childByFieldName("hiding")) |hidden|
            .{ .hiding = try self.items(hidden) }
        else
            .all;
        return .{
            .module = try self.dupe(module_node),
            .selects = selects,
            .qualifier = if (node.childByFieldName("qualifier")) |q| try self.dupe(q) else null,
            .span = spanOf(node, self.source_id),
        };
    }

    fn items(self: *Walker, node: ts.Node) ![]const cst.Item {
        var out: std.ArrayList(cst.Item) = .empty;
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "item")) {
                    if (child.childByFieldName("name")) |name| {
                        const kind: cst.Item.Kind = if (std.mem.eql(u8, name.grammarKind(), "identifier"))
                            .value
                        else if (child.childByFieldName("constructors") != null)
                            .type_and_constructors
                        else
                            .type;
                        try out.append(self.allocator, .{
                            .name = try self.dupe(name),
                            .kind = kind,
                            .span = spanOf(child, self.source_id),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn signature(self: *Walker, node: ts.Node) !?cst.Signature {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const type_node = try self.requiredField(node, "type") orelse return null;
        const name = try self.dupe(name_node);
        const constraints = if (node.childByFieldName("context")) |c|
            try self.context(c) orelse return null
        else
            &.{};
        const ty = try self.typeExpr(type_node) orelse return null;
        return .{ .name = name, .context = constraints, .type = ty, .span = spanOf(node, self.source_id) };
    }

    fn context(self: *Walker, node: ts.Node) !?[]const cst.ClassConstraint {
        var collected: std.ArrayList(cst.ClassConstraint) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (std.mem.eql(u8, child.grammarKind(), "class_constraint")) {
                    const class_node = try self.requiredField(child, "class") orelse return null;
                    const variable_node = try self.requiredField(child, "variable") orelse return null;
                    try collected.append(self.allocator, .{
                        .class = try self.dupe(class_node),
                        .variable = try self.dupe(variable_node),
                        .span = spanOf(child, self.source_id),
                    });
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return try collected.toOwnedSlice(self.allocator);
    }

    fn definition(self: *Walker, node: ts.Node) !?cst.Definition {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const name = try self.dupe(name_node);
        const params = try self.parameters(node);

        const body_node = try self.requiredField(node, "body") orelse return null;
        const body = try self.expression(body_node) orelse return null;

        return .{
            .name = name,
            .parameters = params,
            .body = body,
            .span = spanOf(node, self.source_id),
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
                            .span = spanOf(child, self.source_id),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return collected.toOwnedSlice(self.allocator);
    }

    fn binding(self: *Walker, node: ts.Node) !?cst.Binding {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const name = try self.dupe(name_node);
        const params = try self.parameters(node);

        const value_node = try self.requiredField(node, "value") orelse return null;
        const value = try self.expression(value_node) orelse return null;

        return .{
            .name = name,
            .parameters = params,
            .value = value,
            .span = spanOf(node, self.source_id),
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

    const ExpressionKind = enum {
        identifier,
        qualified_identifier,
        kind,
        number,
        boolean,
        string,
        regex,
        field_access,
        navigation,
        leading_navigation,
        application,
        dollar_application,
        infix_application,
        operator_name,
        left_section,
        right_section,
        if_expression,
        case_expression,
        type_identifier,
        qualified_type_identifier,
        lambda,
        let_expression,
        do_expression,
        list,
        record,
        parenthesized,
    };

    const LiteralKind = enum { number, string, regex, boolean, kind };

    fn expression(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Expression {
        const span = spanOf(node, self.source_id);
        const kind = node.grammarKind();

        if (std.meta.stringToEnum(ExpressionKind, kind)) |known| switch (known) {
            .identifier, .qualified_identifier => {
                return .{ .kind = .{ .name = try self.dupe(node) }, .span = span };
            },
            .kind => return .{ .kind = .{ .kind_test = try self.kindName(node) }, .span = span },
            .number => {
                const text = textOf(node, self.source);
                const value = std.fmt.parseInt(i64, text, 10) catch {
                    try self.sink.report(.parse, span, "integer literal out of range", .{});
                    return null;
                };
                return .{ .kind = .{ .number = value }, .span = span };
            },
            .boolean => {
                const text = textOf(node, self.source);
                return .{
                    .kind = .{ .boolean = std.mem.eql(u8, text, "true") },
                    .span = span,
                };
            },
            .string => {
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
            },
            .regex => {
                // `r"..."`: two leading bytes, one trailing.
                const text = textOf(node, self.source);
                const body = if (text.len >= 3) text[2 .. text.len - 1] else text;
                return .{
                    .kind = .{ .regex = try self.allocator.dupe(u8, body) },
                    .span = span,
                };
            },
            .field_access => return self.projection(node, span),
            .navigation, .leading_navigation => return self.navigation(node, span),
            .application, .dollar_application => return self.application(node, span),
            .infix_application => return self.infixApplication(node, span),
            .operator_name, .left_section, .right_section => return self.section(node, span),
            .if_expression => return self.ifExpr(node, span),
            .case_expression => return self.caseExpr(node, span),
            .type_identifier, .qualified_type_identifier => {
                return cst.Expression{
                    .kind = .{ .constructor = try self.dupe(node) },
                    .span = span,
                };
            },
            .lambda => return self.lambda(node, span),
            .let_expression => return self.letExpr(node, span),
            .do_expression => return self.doExpr(node, span),
            .list => return self.list(node, span),
            .record => return self.record(node, span),
            .parenthesized => {
                const inner_node = node.namedChild(0) orelse {
                    try self.missingField(node, "expression");
                    return null;
                };
                const inner = try self.expression(inner_node) orelse return null;
                return .{
                    .kind = .{ .parenthesized = try self.boxed(inner) },
                    .span = span,
                };
            },
        };

        if (binaryOperatorOf(kind)) |_| {
            return self.binary(node, span);
        }

        // An ERROR or MISSING node, already reported by `collectSyntaxErrors`.
        if (node.isError() or node.isMissing()) return null;

        try self.sink.report(.parse, span, "unexpected {s}", .{kind});
        return null;
    }

    /// `r.l`, or the section `_.l`.
    fn projection(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const record_node = try self.requiredField(node, "record") orelse return null;
        const subject: ?cst.Expression = if (std.mem.eql(u8, textOf(record_node, self.source), "_"))
            null
        else
            try self.expression(record_node) orelse return null;
        const label_node = try self.requiredField(node, "field") orelse return null;
        return .{
            .kind = .{ .projection = try self.boxed(cst.Projection{
                .record = subject,
                .label = try self.dupe(label_node),
            }) },
            .span = span,
        };
    }

    /// `n#f`, or a leading `#f` with no `node` child.
    fn navigation(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const subject: ?cst.Expression = if (node.childByFieldName("node")) |n|
            try self.expression(n) orelse return null
        else
            null;
        const field_node = try self.requiredField(node, "field") orelse return null;
        return .{
            .kind = .{ .navigation = try self.boxed(cst.Navigation{
                .node = subject,
                .field = try self.dupe(field_node),
            }) },
            .span = span,
        };
    }

    fn application(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const fn_node = try self.requiredField(node, "function") orelse return null;
        const arg_node = try self.requiredField(node, "argument") orelse return null;
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

    /// ``a `f` b``, as `f a b`.
    fn infixApplication(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const left_node = try self.requiredField(node, "left") orelse return null;
        const fn_node = try self.requiredField(node, "function") orelse return null;
        const right_node = try self.requiredField(node, "right") orelse return null;
        const left = try self.expression(left_node) orelse return null;
        const function = try self.expression(fn_node) orelse return null;
        const right = try self.expression(right_node) orelse return null;
        const partial: cst.Expression = .{
            .kind = .{ .apply = try self.boxed(cst.Apply{
                .function = function,
                .argument = left,
            }) },
            .span = left.span.join(function.span),
        };
        return .{
            .kind = .{ .apply = try self.boxed(cst.Apply{
                .function = partial,
                .argument = right,
            }) },
            .span = span,
        };
    }

    /// `(op)`, `(e op)` or `(op e)`.
    fn section(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const op_node = try self.requiredField(node, "operator") orelse return null;
        const operator: cst.SectionOperator = if (std.mem.eql(u8, op_node.grammarKind(), "backtick_operator")) blk: {
            const fn_node = try self.requiredField(op_node, "function") orelse return null;
            break :blk .{ .function = try self.expression(fn_node) orelse return null };
        } else if (std.mem.eql(u8, textOf(op_node, self.source), "$"))
            .dollar
        else
            .{ .binary = operatorFromSpelling(textOf(op_node, self.source)) orelse {
                try self.sink.report(.parse, span, "unknown operator", .{});
                return null;
            } };

        const left: ?cst.Expression = if (node.childByFieldName("left")) |n|
            try self.expression(n) orelse return null
        else
            null;
        const right: ?cst.Expression = if (node.childByFieldName("right")) |n|
            try self.expression(n) orelse return null
        else
            null;

        return .{
            .kind = .{ .section = try self.boxed(cst.Section{
                .operator = operator,
                .left = left,
                .right = right,
            }) },
            .span = span,
        };
    }

    fn binary(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const left_node = try self.requiredField(node, "left") orelse return null;
        const right_node = try self.requiredField(node, "right") orelse return null;

        const operator = if (node.childByFieldName("operator")) |op_node|
            operatorFromSpelling(textOf(op_node, self.source)) orelse {
                try self.sink.report(.parse, span, "unknown operator", .{});
                return null;
            }
        else
            // `union`, `pipe`, `logical_and`, `logical_or`, `composition`,
            // `then` and `cons` spell their operator in the rule name rather
            // than an `operator:` field.
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

    fn dataDeclaration(self: *Walker, node: ts.Node) !?cst.DataDeclaration {
        const name_node = try self.requiredField(node, "name") orelse return null;
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
            .span = spanOf(node, self.source_id),
        };
    }

    fn typeAlias(self: *Walker, node: ts.Node) !?cst.TypeAlias {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const type_node = try self.requiredField(node, "type") orelse return null;
        const name = try self.dupe(name_node);
        var params: std.ArrayList(cst.Identifier) = .empty;

        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "parameter")) {
                        try params.append(self.allocator, try self.dupe(cursor.node()));
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        const ty = try self.typeExpr(type_node) orelse return null;
        return .{
            .name = name,
            .parameters = try params.toOwnedSlice(self.allocator),
            .type = ty,
            .span = spanOf(node, self.source_id),
        };
    }

    fn constructorDeclaration(self: *Walker, node: ts.Node) !?cst.ConstructorDeclaration {
        const name_node = try self.requiredField(node, "name") orelse return null;
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
            .span = spanOf(node, self.source_id),
        };
    }

    fn caseExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const scrutinee_node = try self.requiredField(node, "scrutinee") orelse return null;
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
        const pattern_node = try self.requiredField(node, "pattern") orelse return null;
        const body_node = try self.requiredField(node, "body") orelse return null;
        const parsed = try self.pattern(pattern_node) orelse return null;
        const guard: ?cst.Expression = if (node.childByFieldName("guard")) |guard_node|
            try self.expression(guard_node) orelse return null
        else
            null;
        const body = try self.expression(body_node) orelse return null;
        return .{
            .pattern = parsed,
            .guard = guard,
            .body = body,
            .span = spanOf(node, self.source_id),
        };
    }

    fn pattern(self: *Walker, node: ts.Node) error{OutOfMemory}!?cst.Pattern {
        const span = spanOf(node, self.source_id);
        const kind = node.grammarKind();
        if (std.mem.eql(u8, kind, "identifier")) {
            return .{ .kind = .{ .variable = try self.dupe(node) }, .span = span };
        }
        if (isConstructor(kind)) {
            return .{
                .kind = .{ .constructor = .{ .name = try self.dupe(node), .arguments = &.{} } },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "parenthesized_pattern")) {
            const inner = node.namedChild(0) orelse {
                try self.missingField(node, "pattern");
                return null;
            };
            return try self.pattern(inner);
        }
        if (std.mem.eql(u8, kind, "constructor_pattern")) {
            const name_node = try self.requiredField(node, "constructor") orelse return null;
            var arguments: std.ArrayList(cst.Pattern) = .empty;
            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                while (true) {
                    if (cursor.fieldName()) |field| {
                        if (std.mem.eql(u8, field, "argument")) {
                            const argument = try self.pattern(cursor.node()) orelse return null;
                            try arguments.append(self.allocator, argument);
                        }
                    }
                    if (!cursor.gotoNextSibling()) break;
                }
            }
            return .{
                .kind = .{ .constructor = .{
                    .name = try self.dupe(name_node),
                    .arguments = try arguments.toOwnedSlice(self.allocator),
                } },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "list_pattern")) {
            var elements: std.ArrayList(cst.Pattern) = .empty;
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                const child = node.namedChild(i).?;
                if (child.isExtra()) continue;
                const element = try self.pattern(child) orelse return null;
                try elements.append(self.allocator, element);
            }
            return .{
                .kind = .{ .list = try elements.toOwnedSlice(self.allocator) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "cons_pattern")) {
            const head_node = try self.requiredField(node, "head") orelse return null;
            const tail_node = try self.requiredField(node, "tail") orelse return null;
            const head = try self.pattern(head_node) orelse return null;
            const tail = try self.pattern(tail_node) orelse return null;
            return .{
                .kind = .{ .cons = try self.boxed(cst.Pattern.Cons{ .head = head, .tail = tail }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "as_pattern")) {
            const name_node = try self.requiredField(node, "name") orelse return null;
            const inner_node = try self.requiredField(node, "pattern") orelse return null;
            const inner = try self.pattern(inner_node) orelse return null;
            return .{
                .kind = .{ .as = try self.boxed(cst.Pattern.As{
                    .name = try self.dupe(name_node),
                    .name_span = spanOf(name_node, self.source_id),
                    .pattern = inner,
                }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "conjunction_pattern")) {
            const left_node = try self.requiredField(node, "left") orelse return null;
            const right_node = try self.requiredField(node, "right") orelse return null;
            const left = try self.pattern(left_node) orelse return null;
            const right = try self.pattern(right_node) orelse return null;
            return .{
                .kind = .{ .conjunction = try self.boxed(cst.Pattern.Conjunction{ .left = left, .right = right }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "view_pattern")) {
            const view_node = try self.requiredField(node, "view") orelse return null;
            const inner_node = try self.requiredField(node, "pattern") orelse return null;
            const function = try self.expression(view_node) orelse return null;
            const inner = try self.pattern(inner_node) orelse return null;
            return .{
                .kind = .{ .view = try self.boxed(cst.Pattern.View{
                    .function = function,
                    .written = try self.dupe(view_node),
                    .pattern = inner,
                }) },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "node_pattern")) return try self.nodePattern(node, span);
        if (std.meta.stringToEnum(LiteralKind, kind)) |_| {
            const literal = try self.expression(node) orelse return null;
            return .{
                .kind = switch (literal.kind) {
                    .number => |n| .{ .literal = .{ .number = n } },
                    .string => |s| .{ .literal = .{ .string = s } },
                    .regex => |r| .{ .literal = .{ .regex = r } },
                    .kind_test => |k| .{ .literal = .{ .kind = k } },
                    .boolean => |b| .{ .boolean = b },
                    else => unreachable,
                },
                .span = span,
            };
        }
        if (node.isError() or node.isMissing()) return null;

        try self.sink.report(.parse, span, "unexpected {s}", .{kind});
        return null;
    }

    /// A `kind` node's name.
    fn kindName(self: *Walker, node: ts.Node) error{OutOfMemory}![]const u8 {
        // The lexeme includes the leading `:`, which is punctuation.
        return try self.allocator.dupe(u8, textOf(node, self.source)[1..]);
    }

    fn nodePattern(self: *Walker, node: ts.Node, span: Span) error{OutOfMemory}!?cst.Pattern {
        const kind_node = node.childByFieldName("kind");
        var fields: std.ArrayList(cst.Pattern.Node.Field) = .empty;
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "field")) {
                        const field_node = cursor.node();
                        const name_node = try self.requiredField(field_node, "name") orelse return null;
                        const pattern_node = try self.requiredField(field_node, "pattern") orelse return null;
                        try fields.append(self.allocator, .{
                            .name = try self.dupe(name_node),
                            .name_span = spanOf(name_node, self.source_id),
                            .pattern = try self.pattern(pattern_node) orelse return null,
                            .span = spanOf(field_node, self.source_id),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }
        return .{
            .kind = .{ .node = try self.boxed(cst.Pattern.Node{
                .kind = if (kind_node) |k| try self.kindName(k) else null,
                .kind_span = if (kind_node) |k| spanOf(k, self.source_id) else .unknown,
                .fields = try fields.toOwnedSlice(self.allocator),
            }) },
            .span = span,
        };
    }

    fn ifExpr(self: *Walker, node: ts.Node, span: Span) !?cst.Expression {
        const cond_node = try self.requiredField(node, "condition") orelse return null;
        const then_node = try self.requiredField(node, "consequence") orelse return null;
        const else_node = try self.requiredField(node, "alternative") orelse return null;
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
        const body_node = try self.requiredField(node, "body") orelse return null;
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
        const group_node = try self.requiredField(node, "bindings") orelse return null;
        const binding_list = try self.bindings(group_node);
        const body_node = try self.requiredField(node, "body") orelse return null;
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
                const pattern_node = try self.requiredField(child, "pattern") orelse continue;
                const value_node = try self.requiredField(child, "value") orelse continue;
                const parsed = try self.pattern(pattern_node) orelse continue;
                if (try self.expression(value_node)) |value| {
                    try statements.append(self.allocator, .{ .bind = .{
                        .pattern = parsed,
                        .value = value,
                        .span = spanOf(child, self.source_id),
                    } });
                }
            } else if (std.mem.eql(u8, kind, "let_statement")) {
                const group_node = try self.requiredField(child, "bindings") orelse continue;
                try statements.append(self.allocator, .{ .let = .{
                    .bindings = try self.bindings(group_node),
                    .span = spanOf(child, self.source_id),
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
                    const name_node = try self.requiredField(child, "name") orelse {
                        if (!cursor.gotoNextSibling()) break;
                        continue;
                    };
                    const value_node = try self.requiredField(child, "value") orelse {
                        if (!cursor.gotoNextSibling()) break;
                        continue;
                    };
                    const name = try self.dupe(name_node);
                    if (try self.expression(value_node)) |value| {
                        try fields.append(self.allocator, .{
                            .name = name,
                            .value = value,
                            .span = spanOf(child, self.source_id),
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
        const name_node = try self.requiredField(node, "constructor") orelse return null;
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
        const span = spanOf(node, self.source_id);
        const kind = node.grammarKind();

        if (isConstructor(kind)) {
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
            const from_node = try self.requiredField(node, "from") orelse return null;
            const to_node = try self.requiredField(node, "to") orelse return null;
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
            const in_node = try self.requiredField(node, "input") orelse return null;
            const out_node = try self.requiredField(node, "output") orelse return null;
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
                        const name_node = try self.requiredField(child, "name") orelse {
                            if (!cursor.gotoNextSibling()) break;
                            continue;
                        };
                        const type_node = try self.requiredField(child, "type") orelse {
                            if (!cursor.gotoNextSibling()) break;
                            continue;
                        };
                        const name = try self.dupe(name_node);
                        if (try self.typeExpr(type_node)) |ty| {
                            try fields.append(self.allocator, .{
                                .name = name,
                                .type = ty,
                                .span = spanOf(child, self.source_id),
                            });
                        }
                    }
                    if (!cursor.gotoNextSibling()) break;
                }
            }

            const row = if (node.childByFieldName("row")) |row_node| try self.dupe(row_node) else null;
            return cst.Type{
                .kind = .{ .record = .{
                    .fields = try fields.toOwnedSlice(self.allocator),
                    .row = row,
                } },
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
    if (std.mem.eql(u8, kind, "composition")) return .compose;
    if (std.mem.eql(u8, kind, "then")) return .then;
    if (std.mem.eql(u8, kind, "cons")) return .cons;
    return null;
}

fn operatorFromSpelling(text: []const u8) ?cst.BinaryOperator {
    for (std.enums.values(cst.BinaryOperator)) |op| {
        if (std.mem.eql(u8, text, op.spelling())) return op;
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

    var result = try parser.parseCollecting(source, .entry);
    defer result.deinit();

    try testing.expectEqual(0, result.diagnostics.len);

    const actual = try result.source_file.sexprAlloc(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "a header and imports precede the declarations" {
    try expectSexpr(
        \\module A.B (f, T(..), U) for javascript, tsx;
        \\import C;
        \\import D (g) as Q;
        \\import Prelude hiding (filter);
        \\f = 1;
    ,
        "(source_file (module A.B (exports f T(..) U) (for javascript tsx)) (import C) (import D (items g) (as Q))" ++
            " (import Prelude (hiding filter)) (define f (params) 1))",
    );
}

test "a qualified name keeps its qualifier" {
    try expectSexpr(
        "f = Q.g (A.B.Just 1);",
        "(source_file (define f (params) (apply Q.g (paren (apply A.B.Just 1)))))",
    );
}

test "children compose with a kind test" {
    try expectSexpr(
        "main root = (children | is_kind :class_declaration) root;",
        "(source_file (define main (params root) " ++
            "(apply (paren (| children (apply is_kind (kind class_declaration)))) root)))",
    );
}

test "navigation binds tighter than application" {
    try expectSexpr(
        "main = f x#name;",
        "(source_file (define main (params) (apply f (field x name))))",
    );
}

test "a leading navigation has no node" {
    try expectSexpr(
        "main = #name;",
        "(source_file (define main (params) (field . name)))",
    );
}

test "projection binds tighter than application" {
    try expectSexpr(
        "main = f x.start_byte;",
        "(source_file (define main (params) (apply f (select x start_byte))))",
    );
}

test "an underscore section has no record" {
    try expectSexpr(
        "main = _.start_byte;",
        "(source_file (define main (params) (select _ start_byte)))",
    );
}

test "an underscore section chains" {
    try expectSexpr(
        "main = _.start_point.row;",
        "(source_file (define main (params) (select (select _ start_point) row)))",
    );
}

test "projection chains through navigation" {
    try expectSexpr(
        "main = (range c#name).start_point.row;",
        "(source_file (define main (params) " ++
            "(select (select (paren (apply range (field c name))) start_point) row)))",
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

test "a case pattern nests constructors and binds variables" {
    try expectSexpr(
        "main = case xs of { Cons a (Cons _ Nil) -> a; ys -> 0 };",
        "(source_file (define main (params) " ++
            "(case xs (alt (Cons a (Cons _ Nil)) a) (alt ys 0))))",
    );
}

test "list and cons patterns keep their shape" {
    try expectSexpr(
        "main = case xs of { [] -> 0; [Just a, _] -> a; h:t -> h; a : b : t -> b };",
        "(source_file (define main (params) (case xs " ++
            "(alt (list) 0) " ++
            "(alt (list (Just a) _) a) " ++
            "(alt (: h t) h) " ++
            "(alt (: a (: b t)) b))))",
    );
}

test "a case alternative takes a guard" {
    try expectSexpr(
        "main = case x of { n if n > 0 -> n; _ -> 0 };",
        "(source_file (define main (params) (case x (alt n (if (> n 0)) n) (alt _ 0))))",
    );
}

test "literal patterns keep their values" {
    try expectSexpr(
        "main = case x of { -3 -> 1; \"a\\n\" -> 2; r\"^a\" -> 3; true -> 4; :class_declaration -> 5 };",
        "(source_file (define main (params) (case x " ++
            "(alt -3 1) " ++
            "(alt (string \"a\\n\") 2) " ++
            "(alt (regex \"^a\") 3) " ++
            "(alt true 4) " ++
            "(alt (kind class_declaration) 5))))",
    );
}

test "a bind statement takes a view, an as-pattern and a conjunction" {
    try expectSexpr(
        "main = do { (text -> \"a\") & x@[_] <- xs; x };",
        "(source_file (define main (params) " ++
            "(do (<- (& (view text (string \"a\")) (@ x (list _))) xs) x)))",
    );
}

test "a node pattern takes a kind, fields, or both" {
    try expectSexpr(
        "main = do { c@:call_expression { #function = { #object = o, }, #arguments = _ } <- xs; :comment {} <- ys; c };",
        "(source_file (define main (params) (do " ++
            "(<- (@ c (node (kind call_expression) (#function (node (#object o))) (#arguments _))) xs) " ++
            "(<- (node (kind comment)) ys) " ++
            "c)))",
    );
}

test "cons is right-associative, between comparison and addition" {
    try expectSexpr(
        "main = a + 1 : b:xs = ys;",
        "(source_file (define main (params) (= (: (+ a 1) (: b xs)) ys)))",
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
        "main = do { c <- children; c#name };",
        "(source_file (define main (params) (do (<- c children) (field c name))))",
    );
}

test "a do block with an expression statement" {
    try expectSexpr(
        "main = do { c <- children; guard $ c = c; c };",
        "(source_file (define main (params) (do (<- c children) (>> (apply guard (= c c))) c)))",
    );
}

test "a do-local let statement" {
    try expectSexpr(
        "main = do { c <- children; let n = c#name; n };",
        "(source_file (define main (params) " ++
            "(do (<- c children) (let (bind n (params) (field c name))) n)))",
    );
}

test "a signature" {
    try expectSexpr(
        "main :: Filter node string;",
        "(source_file (signature main (Filter node string)))",
    );
}

test "a function-typed signature" {
    try expectSexpr(
        "f :: Filter node node -> Filter node string;",
        "(source_file (signature f (-> (Filter node node) (Filter node string))))",
    );
}

test "a signature with a context" {
    try expectSexpr(
        "f :: (Eq a, Sized b) => a -> b -> Int;",
        "(source_file (signature f (=> (Eq a) (Sized b)) (-> a (-> b Int))))",
    );
}

test "an open record type names its row" {
    try expectSexpr(
        "f :: {start_byte: t | r} -> t;",
        "(source_file (signature f (-> (record_type (start_byte t) | r) t)))",
    );
}

test "a record type of only a row" {
    try expectSexpr(
        "f :: {| r} -> Int;",
        "(source_file (signature f (-> (record_type | r) Int)))",
    );
}

test "a type alias keeps its parameters and body" {
    try expectSexpr(
        "type Named r = {name: String | r};",
        "(source_file (type Named (params r) (record_type (name String) | r)))",
    );
}

test "a data declaration and a type alias side by side" {
    try expectSexpr(
        "data Box a = Box a; type Pred = Node -> Bool;",
        "(source_file (data Box (params a) (con Box a)) (type Pred (params) (-> Node Bool)))",
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

test "union is spelled <|> and binds tighter than pipe" {
    try expectSexpr(
        "main = a <|> b | c;",
        "(source_file (define main (params) (| (<|> a b) c)))",
    );
}

test "dollar application is right-associative plain application" {
    try expectSexpr(
        "main = f $ g $ a <|> b;",
        "(source_file (define main (params) (apply f (apply g (<|> a b)))))",
    );
}

test "composition is right-associative and looser than application" {
    try expectSexpr(
        "main = f x . g . h y;",
        "(source_file (define main (params) (. (apply f x) (. g (apply h y)))))",
    );
}

test "then is left-associative, between dollar and pipe" {
    try expectSexpr(
        "main = f $ a >> b >> c | d;",
        "(source_file (define main (params) (apply f (>> (>> a b) (| c d)))))",
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

    var result = try parser.parseCollecting("main = 1 + 2;", .entry);
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

    var result = try parser.parseCollecting("main = (1 + 2;", .entry);
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
    , .entry);
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

    var result = try parser.parseCollecting("main =", .entry);
    defer result.deinit();

    try testing.expectEqual(1, result.diagnostics.len);
    const span = result.diagnostics[0].span;
    try testing.expectEqual(0, span.start_byte);
    try testing.expectEqual(6, span.end_byte);
}

test "every span names the source it was parsed as" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    const library: diagnostic.SourceId = @enumFromInt(3);
    var result = try parser.parseCollecting("f x = x;", library);
    defer result.deinit();

    try testing.expectEqual(library, result.source_file.span.source);
    const definition = result.source_file.declarations[0].definition;
    try testing.expectEqual(library, definition.span.source);
    try testing.expectEqual(library, definition.parameters[0].span.source);
    try testing.expectEqual(library, definition.body.span.source);
}

test "a syntax error names the source it was parsed as" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();

    const library: diagnostic.SourceId = @enumFromInt(3);
    var result = try parser.parseCollecting("main =", library);
    defer result.deinit();

    try testing.expectEqual(1, result.diagnostics.len);
    try testing.expectEqual(library, result.diagnostics[0].span.source);
}

test "several declarations parse independently" {
    try expectSexpr(
        "a = 1;\nb = 2;",
        "(source_file (define a (params) 1) (define b (params) 2))",
    );
}
