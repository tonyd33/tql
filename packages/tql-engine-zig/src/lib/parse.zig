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
                } else if (std.mem.eql(u8, kind, "pattern_synonym")) {
                    if (try self.patternSynonym(child)) |p| {
                        try declarations.append(self.allocator, .{ .pattern_synonym = p });
                    }
                } else if (std.mem.eql(u8, kind, "pattern_signature")) {
                    if (try self.patternSignature(child)) |p| {
                        try declarations.append(self.allocator, .{ .pattern_signature = p });
                    }
                } else if (std.mem.eql(u8, kind, "class_declaration")) {
                    if (try self.classDeclaration(child)) |c| {
                        try declarations.append(self.allocator, .{ .class_declaration = c });
                    }
                } else if (std.mem.eql(u8, kind, "instance_declaration")) {
                    if (try self.instanceDeclaration(child)) |i| {
                        try declarations.append(self.allocator, .{ .instance_declaration = i });
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
                    if (child.childByFieldName("synonym")) |name| {
                        try out.append(self.allocator, .{
                            .name = try self.dupe(name),
                            .kind = .synonym,
                            .span = spanOf(child, self.source_id),
                        });
                    } else if (child.childByFieldName("module")) |name| {
                        try out.append(self.allocator, .{
                            .name = try self.dupe(name),
                            .kind = .module,
                            .span = spanOf(child, self.source_id),
                        });
                    } else if (child.childByFieldName("name")) |name| {
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
                    const type_node = try self.requiredField(child, "type") orelse return null;
                    try collected.append(self.allocator, .{
                        .class = try self.dupe(class_node),
                        .type = try self.typeExpr(type_node) orelse return null,
                        .span = spanOf(child, self.source_id),
                    });
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        return try collected.toOwnedSlice(self.allocator);
    }

    fn classDeclaration(self: *Walker, node: ts.Node) !?cst.ClassDeclaration {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const parameter_node = try self.requiredField(node, "parameter") orelse return null;
        const superclasses = if (node.childByFieldName("context")) |c|
            try self.context(c) orelse return null
        else
            &.{};

        const methods = try self.fieldChildren(cst.Signature, node, "method", signature) orelse return null;

        return .{
            .name = try self.dupe(name_node),
            .parameter = try self.dupe(parameter_node),
            .superclasses = superclasses,
            .methods = methods,
            .span = spanOf(node, self.source_id),
        };
    }

    fn instanceDeclaration(self: *Walker, node: ts.Node) !?cst.InstanceDeclaration {
        const class_node = try self.requiredField(node, "class") orelse return null;
        const type_node = try self.requiredField(node, "type") orelse return null;
        const constraints = if (node.childByFieldName("context")) |c|
            try self.context(c) orelse return null
        else
            &.{};
        const head = try self.typeExpr(type_node) orelse return null;

        const methods = try self.fieldChildren(cst.Definition, node, "method", definition) orelse return null;

        return .{
            .class = try self.dupe(class_node),
            .head = head,
            .context = constraints,
            .methods = methods,
            .span = spanOf(node, self.source_id),
        };
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
        primitive,
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
        unit,
        tuple,
        tuple_constructor,
        record,
        parenthesized,
        of_shape,
    };

    const LiteralKind = enum { number, string, regex, boolean, kind };

    fn expression(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Expression {
        const span = spanOf(node, self.source_id);
        const kind = node.grammarKind();

        if (std.meta.stringToEnum(ExpressionKind, kind)) |known| switch (known) {
            .identifier, .qualified_identifier => {
                return .{ .kind = .{ .name = try self.dupe(node) }, .span = span };
            },
            .primitive => return .{ .kind = .{ .primitive = try self.dupe(node) }, .span = span },
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
            .list => return .{ .kind = .{ .list = try self.children(cst.Expression, node, expression) orelse return null }, .span = span },
            .unit => return .{ .kind = .{ .tuple = &.{} }, .span = span },
            .tuple => return .{ .kind = .{ .tuple = try self.components(cst.Expression, node, expression) orelse return null }, .span = span },
            .tuple_constructor => return .{ .kind = .{ .tuple_constructor = try self.tupleArity(node) orelse return null }, .span = span },
            .record => return self.record(node, span),
            .of_shape => {
                const pattern_node = try self.requiredField(node, "pattern") orelse return null;
                const shape = try self.pattern(pattern_node) orelse return null;
                return .{ .kind = .{ .of_shape = try self.boxed(shape) }, .span = span };
            },
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
        var deriving: []const cst.DataDeclaration.Derived = &.{};
        var representation: ?cst.DataDeclaration.Representation = null;

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
                    } else if (std.mem.eql(u8, field, "deriving")) {
                        deriving = try self.derivingClause(child);
                    } else if (std.mem.eql(u8, field, "representation")) {
                        representation = .{ .name = try self.dupe(child), .span = spanOf(child, self.source_id) };
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }

        const keyword = try self.requiredField(node, "keyword") orelse return null;
        const newtype = std.mem.eql(u8, keyword.kind(), "newtype");
        if (newtype and (constructors.items.len != 1 or constructors.items[0].fields.len != 1)) {
            try self.sink.report(.parse, spanOf(node, self.source_id), "a `newtype` has one constructor of one field; declare `{s}` with `data`", .{name});
            return null;
        }
        return .{
            .newtype = newtype,
            .name = name,
            .parameters = try params.toOwnedSlice(self.allocator),
            .constructors = try constructors.toOwnedSlice(self.allocator),
            .deriving = deriving,
            .representation = representation,
            .span = spanOf(node, self.source_id),
        };
    }

    fn derivingClause(self: *Walker, node: ts.Node) ![]const cst.DataDeclaration.Derived {
        var classes: std.ArrayList(cst.DataDeclaration.Derived) = .empty;
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |field| {
                    if (std.mem.eql(u8, field, "class")) {
                        const child = cursor.node();
                        try classes.append(self.allocator, .{
                            .class = try self.dupe(child),
                            .span = spanOf(child, self.source_id),
                        });
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }
        return try classes.toOwnedSlice(self.allocator);
    }

    fn typeAlias(self: *Walker, node: ts.Node) !?cst.TypeAlias {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const type_node = try self.requiredField(node, "type") orelse return null;
        const name = try self.dupe(name_node);
        const params = try self.fieldChildren(cst.Identifier, node, "parameter", identifier) orelse return null;

        const ty = try self.typeExpr(type_node) orelse return null;
        return .{
            .name = name,
            .parameters = params,
            .type = ty,
            .span = spanOf(node, self.source_id),
        };
    }

    fn patternSynonym(self: *Walker, node: ts.Node) !?cst.PatternSynonym {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const pattern_node = try self.requiredField(node, "pattern") orelse return null;
        return .{
            .name = try self.dupe(name_node),
            .parameters = try self.parameters(node),
            .body = try self.pattern(pattern_node) orelse return null,
            .span = spanOf(node, self.source_id),
        };
    }

    fn patternSignature(self: *Walker, node: ts.Node) !?cst.PatternSignature {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const type_node = try self.requiredField(node, "type") orelse return null;
        return .{
            .name = try self.dupe(name_node),
            .type = try self.typeExpr(type_node) orelse return null,
            .span = spanOf(node, self.source_id),
        };
    }

    fn constructorDeclaration(self: *Walker, node: ts.Node) !?cst.ConstructorDeclaration {
        const name_node = try self.requiredField(node, "name") orelse return null;
        const name = try self.dupe(name_node);
        const fields = try self.fieldChildren(cst.Type, node, "field", typeExpr) orelse return null;

        return .{
            .name = name,
            .fields = fields,
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
            const arguments = try self.fieldChildren(cst.Pattern, node, "argument", pattern) orelse return null;
            return .{
                .kind = .{ .constructor = .{
                    .name = try self.dupe(name_node),
                    .arguments = arguments,
                } },
                .span = span,
            };
        }
        if (std.mem.eql(u8, kind, "list_pattern")) {
            return .{ .kind = .{ .list = try self.children(cst.Pattern, node, pattern) orelse return null }, .span = span };
        }
        if (std.mem.eql(u8, kind, "tuple_pattern")) {
            return .{ .kind = .{ .tuple = try self.components(cst.Pattern, node, pattern) orelse return null }, .span = span };
        }
        if (std.mem.eql(u8, kind, "unit")) {
            return .{ .kind = .{ .tuple = &.{} }, .span = span };
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

    /// The components of the tuple `node`, converted by `convert`. Null
    /// after reporting more than `cst.max_tuple_arity`.
    fn components(
        self: *Walker,
        comptime T: type,
        node: ts.Node,
        comptime convert: fn (*Walker, ts.Node) (error{OutOfMemory})!?T,
    ) (error{OutOfMemory})!?[]const T {
        const converted = try self.children(T, node, convert) orelse return null;
        if (!try self.withinTupleArity(converted.len, node)) return null;
        return converted;
    }

    /// The number of components `(,..)` constructs: one more than its
    /// commas. Null after reporting more than `cst.max_tuple_arity`.
    fn tupleArity(self: *Walker, node: ts.Node) (error{OutOfMemory})!?u8 {
        var arity: usize = 1;
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (std.mem.eql(u8, node.child(i).?.kind(), ",")) arity += 1;
        }
        if (!try self.withinTupleArity(arity, node)) return null;
        return @intCast(arity);
    }

    /// Whether a tuple of `arity` components is allowed, reporting at `node`
    /// when it is not.
    fn withinTupleArity(self: *Walker, arity: usize, node: ts.Node) (error{OutOfMemory})!bool {
        if (arity <= cst.max_tuple_arity) return true;
        try self.sink.report(.parse, spanOf(node, self.source_id), "a tuple has at most {d} components, given {d}", .{ cst.max_tuple_arity, arity });
        return false;
    }

    /// Each child of `node` under `field`, converted by `convert`.
    fn fieldChildren(
        self: *Walker,
        comptime T: type,
        node: ts.Node,
        field: []const u8,
        comptime convert: anytype,
    ) (error{OutOfMemory})!?[]const T {
        var converted: std.ArrayList(T) = .empty;
        var cursor = node.walk();
        defer cursor.destroy();
        if (cursor.gotoFirstChild()) {
            while (true) {
                if (cursor.fieldName()) |name| {
                    if (std.mem.eql(u8, name, field)) {
                        try converted.append(self.allocator, try convert(self, cursor.node()) orelse return null);
                    }
                }
                if (!cursor.gotoNextSibling()) break;
            }
        }
        return try converted.toOwnedSlice(self.allocator);
    }

    fn identifier(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Identifier {
        return try self.dupe(node);
    }

    /// Each named child of `node` but comments, converted by `convert`.
    fn children(
        self: *Walker,
        comptime T: type,
        node: ts.Node,
        comptime convert: fn (*Walker, ts.Node) (error{OutOfMemory})!?T,
    ) (error{OutOfMemory})!?[]const T {
        var converted: std.ArrayList(T) = .empty;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            const child = node.namedChild(i).?;
            if (child.isExtra()) continue;
            try converted.append(self.allocator, try convert(self, child) orelse return null);
        }
        return try converted.toOwnedSlice(self.allocator);
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

    fn isBuiltinConstructor(node: ts.Node) bool {
        return std.mem.eql(u8, node.kind(), "tuple_constructor") or std.mem.eql(u8, node.kind(), "function_constructor");
    }

    /// Preconditions:
    /// - `isBuiltinConstructor(node)`.
    fn builtinConstructor(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.BuiltinConstructor {
        if (std.mem.eql(u8, node.kind(), "function_constructor")) return .function;
        return .{ .tuple = try self.tupleArity(node) orelse return null };
    }

    fn typeApplication(self: *Walker, node: ts.Node, span: Span) (error{OutOfMemory})!?cst.Type {
        const head: cst.TypeApplication.Head = if (node.childByFieldName("variable")) |variable|
            .{ .variable = try self.dupe(variable) }
        else head: {
            const constructor = try self.requiredField(node, "constructor") orelse return null;
            if (isBuiltinConstructor(constructor)) break :head .{ .builtin = try self.builtinConstructor(constructor) orelse return null };
            break :head .{ .constructor = try self.dupe(constructor) };
        };
        const arguments = try self.fieldChildren(cst.Type, node, "argument", typeExpr) orelse return null;

        return cst.Type{
            .kind = .{ .application = try self.boxed(cst.TypeApplication{
                .head = head,
                .arguments = arguments,
            }) },
            .span = span,
        };
    }

    fn typeExpr(self: *Walker, node: ts.Node) (error{OutOfMemory})!?cst.Type {
        const span = spanOf(node, self.source_id);
        const kind = node.kind();

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
        if (std.mem.eql(u8, kind, "tuple_type")) {
            return cst.Type{ .kind = .{ .tuple = try self.components(cst.Type, node, typeExpr) orelse return null }, .span = span };
        }
        if (std.mem.eql(u8, kind, "unit")) {
            return cst.Type{ .kind = .{ .tuple = &.{} }, .span = span };
        }
        if (isBuiltinConstructor(node)) {
            return cst.Type{ .kind = .{ .builtin_constructor = try self.builtinConstructor(node) orelse return null }, .span = span };
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
