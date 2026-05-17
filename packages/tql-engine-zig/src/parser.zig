//! Parser module for TQL (Tree Query Language)
//! Parses TQL source code into AST using tree-sitter

const std = @import("std");
const ts = @import("tree-sitter");
const ast = @import("./ast.zig");

// External tree-sitter parser (will be linked from tree-sitter-tql)
extern fn tree_sitter_tql() *ts.Language;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    ts_parser: *ts.Parser,

    pub fn init(allocator: std.mem.Allocator) !Parser {
        const ts_parser = ts.Parser.create();
        errdefer ts_parser.destroy();

        const language = tree_sitter_tql();
        try ts_parser.setLanguage(language);

        return Parser{
            .allocator = allocator,
            .ts_parser = ts_parser,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ts_parser.destroy();
    }

    // TODO: Error if parsing fails!!!
    pub fn parse(self: *Parser, source: []const u8) !ast.SourceFile {
        const tree = self.ts_parser.parseString(source, null) orelse return error.ParseFailed;
        defer tree.destroy();

        const root_node = tree.rootNode();
        return try self.parseSourceFile(root_node, source);
    }

    fn nodeText(node: ts.Node, source: []const u8) []const u8 {
        const start = node.startByte();
        const end = node.endByte();
        return source[start..end];
    }

    fn getChildByFieldName(node: ts.Node, field_name: []const u8) ?ts.Node {
        return node.childByFieldName(field_name);
    }

    fn expectChildByFieldName(node: ts.Node, field_name: []const u8) !ts.Node {
        return node.childByFieldName(field_name) orelse error.MissingRequiredField;
    }

    fn getNodeType(node: ts.Node) []const u8 {
        return node.grammarKind();
    }

    // TODO: We should really use the emitted field/kind ids...
    fn parseSourceFile(self: *Parser, node: ts.Node, source: []const u8) !ast.SourceFile {
        var items = std.ArrayList(ast.SourceItem).empty;
        defer items.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) {
            return ast.SourceFile{ .items = &.{} };
        }

        while (true) {
            const child = cursor.node();
            const node_type = getNodeType(child);

            if (std.mem.eql(u8, node_type, "directive")) {
                const directive = try self.parseDirective(child, source);
                try items.append(self.allocator, .{ .directive = directive });
            } else if (std.mem.eql(u8, node_type, "query_definition")) {
                const query = try self.parseQueryDefinition(child, source);
                try items.append(self.allocator, .{ .query = query });
            }else if (std.mem.eql(u8, node_type, "query_body")) {
                const query_body = try self.parseQueryBody(child, source);
                try items.append(self.allocator, .{ .query_body = query_body });
            }

            if (!cursor.gotoNextSibling()) break;
        }

        return ast.SourceFile{
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseDirective(self: *Parser, node: ts.Node, source: []const u8) !ast.Directive {
        var cursor = node.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) return error.InvalidDirective;

        while (true) {
            const child = cursor.node();
            const node_type = getNodeType(child);

            if (std.mem.eql(u8, node_type, "language_directive")) {
                return .{ .language = try self.parseLanguageDirective(child, source) };
            } else if (std.mem.eql(u8, node_type, "import_directive")) {
                return .{ .import = try self.parseImportDirective(child, source) };
            }

            if (!cursor.gotoNextSibling()) break;
        }

        return error.InvalidDirective;
    }

    fn parseLanguageDirective(self: *Parser, node: ts.Node, source: []const u8) !ast.LanguageDirective {
        const language_node = try expectChildByFieldName(node, "language");
        const language = try self.parseStringLiteral(language_node, source);
        return ast.LanguageDirective{ .language = language };
    }

    fn parseImportDirective(self: *Parser, node: ts.Node, source: []const u8) !ast.ImportDirective {
        const path_node = try expectChildByFieldName(node, "path");
        const path = try self.parseStringLiteral(path_node, source);
        return ast.ImportDirective{ .path = path };
    }

    // ========================================================================
    // Query Definition Parsing
    // ========================================================================

    fn parseQueryDefinition(self: *Parser, node: ts.Node, source: []const u8) !ast.QueryDefinition {
        const name_node = try expectChildByFieldName(node, "name");
        const name = nodeText(name_node, source);

        var parameters: []const ast.Parameter = &[_]ast.Parameter{};
        var return_type: ?ast.Type = null;

        // Parameters and return_type_annotation don't have field names, find by type
        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "parameters")) {
                    parameters = try self.parseParameters(child, source);
                } else if (std.mem.eql(u8, child_type, "return_type_annotation")) {
                    const type_node = try expectChildByFieldName(child, "type");
                    return_type = try self.parseType(type_node, source);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        const body_node = try expectChildByFieldName(node, "body");
        const body = try self.parseQueryBody(body_node, source);

        return ast.QueryDefinition{
            .name = try self.allocator.dupe(u8, name),
            .parameters = parameters,
            .return_type = return_type,
            .body = body,
        };
    }

    fn parseParameters(self: *Parser, node: ts.Node, source: []const u8) ![]const ast.Parameter {
        var params = std.ArrayList(ast.Parameter).empty;
        defer params.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) {
            return try params.toOwnedSlice(self.allocator);
        }

        while (true) {
            const child = cursor.node();
            const node_type = getNodeType(child);

            if (std.mem.eql(u8, node_type, "parameter")) {
                const param = try self.parseParameter(child, source);
                try params.append(self.allocator, param);
            }

            if (!cursor.gotoNextSibling()) break;
        }

        return try params.toOwnedSlice(self.allocator);
    }

    fn parseParameter(self: *Parser, node: ts.Node, source: []const u8) !ast.Parameter {
        const name_node = try expectChildByFieldName(node, "name");
        const name = try self.parseVariable(name_node, source);

        const param_type = if (getChildByFieldName(node, "type")) |type_node|
            try self.parseType(type_node, source)
        else
            null;

        return ast.Parameter{
            .name = name,
            .type = param_type,
        };
    }

    fn parseQueryBody(self: *Parser, node: ts.Node, source: []const u8) !ast.QueryBody {
        const from_clause = if (getChildByFieldName(node, "from_clause")) |fc|
            try self.parseFromClause(fc, source)
        else
            null;

        const where_clause = if (getChildByFieldName(node, "where_clause")) |wc|
            try self.parseWhereClause(wc, source)
        else
            null;

        const select_node = try expectChildByFieldName(node, "select_clause");
        const select_clause = try self.parseSelectClause(select_node, source);

        return ast.QueryBody{
            .from_clause = from_clause,
            .where_clause = where_clause,
            .select_clause = select_clause,
        };
    }

    // ========================================================================
    // FROM Clause Parsing
    // ========================================================================

    fn parseFromClause(self: *Parser, node: ts.Node, source: []const u8) !ast.FromClause {
        var bindings = std.ArrayList(ast.Binding).empty;
        defer bindings.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (!cursor.gotoFirstChild()) {
            return ast.FromClause{ .bindings = try bindings.toOwnedSlice(self.allocator) };
        }

        while (true) {
            const child = cursor.node();
            const node_type = getNodeType(child);

            if (std.mem.eql(u8, node_type, "binding")) {
                const binding = try self.parseBinding(child, source);
                try bindings.append(self.allocator, binding);
            }

            if (!cursor.gotoNextSibling()) break;
        }

        return ast.FromClause{
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };
    }

    fn parseBinding(self: *Parser, node: ts.Node, source: []const u8) !ast.Binding {
        const expr_node = try expectChildByFieldName(node, "expression");
        const expression = try self.parseExpression(expr_node, source);

        const var_node = try expectChildByFieldName(node, "variable");
        const variable = try self.parseVariable(var_node, source);

        const optional = getChildByFieldName(node, "optional") != null;

        return ast.Binding{
            .expression = expression,
            .variable = variable,
            .optional = optional,
        };
    }

    fn parseNodeSelector(self: *Parser, node: ts.Node, source: []const u8) !ast.NodeSelector {
        const node_type = try self.allocator.dupe(u8, nodeText(node, source));
        return ast.NodeSelector{ .node_type = node_type };
    }

    fn parseFieldAccess(self: *Parser, node: ts.Node, source: []const u8) !ast.FieldAccess {
        const base_node = try expectChildByFieldName(node, "base");
        const base = try self.parseExpression(base_node, source);

        const field_node = try expectChildByFieldName(node, "field");
        const field = try self.allocator.dupe(u8, nodeText(field_node, source));

        return ast.FieldAccess{
            .base = base,
            .field = field,
        };
    }

    fn parseChildNavigation(self: *Parser, node: ts.Node, source: []const u8) !ast.ChildNavigation {
        const parent_node = try expectChildByFieldName(node, "parent");
        const parent = try self.parseExpression(parent_node, source);

        const child_node = try expectChildByFieldName(node, "child");
        const child = try self.parseExpression(child_node, source);

        return ast.ChildNavigation{
            .parent = parent,
            .child = child,
        };
    }

    fn parseDescendantNavigation(self: *Parser, node: ts.Node, source: []const u8) !ast.DescendantNavigation {
        const parent_node = try expectChildByFieldName(node, "parent");
        const parent = try self.parseExpression(parent_node, source);

        const descendant_node = try expectChildByFieldName(node, "descendant");
        const descendant = try self.parseExpression(descendant_node, source);

        return ast.DescendantNavigation{
            .parent = parent,
            .descendant = descendant,
        };
    }

    // ========================================================================
    // WHERE Clause Parsing
    // ========================================================================

    fn parseWhereClause(self: *Parser, node: ts.Node, source: []const u8) !ast.WhereClause {
        const pred_node = try expectChildByFieldName(node, "predicate");
        const predicate = try self.parsePredicate(pred_node, source);
        return ast.WhereClause{ .predicate = predicate };
    }

    fn parsePredicate(self: *Parser, node: ts.Node, source: []const u8) anyerror!ast.Predicate {
        const node_type = getNodeType(node);

        // Handle wrapper predicate node
        if (std.mem.eql(u8, node_type, "predicate")) {
            // Get the first child which is the actual predicate type
            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                return try self.parsePredicate(cursor.node(), source);
            }
            return error.InvalidPredicate;
        }

        if (std.mem.eql(u8, node_type, "comparison")) {
            return .{ .comparison = try self.parseComparison(node, source) };
        } else if (std.mem.eql(u8, node_type, "logical_and")) {
            const logical_and = try self.allocator.create(ast.LogicalAnd);
            logical_and.* = try self.parseLogicalAnd(node, source);
            return .{ .logical_and = logical_and };
        } else if (std.mem.eql(u8, node_type, "logical_or")) {
            const logical_or = try self.allocator.create(ast.LogicalOr);
            logical_or.* = try self.parseLogicalOr(node, source);
            return .{ .logical_or = logical_or };
        } else if (std.mem.eql(u8, node_type, "logical_not")) {
            const logical_not = try self.allocator.create(ast.LogicalNot);
            logical_not.* = try self.parseLogicalNot(node, source);
            return .{ .logical_not = logical_not };
        } else if (std.mem.eql(u8, node_type, "quantified_expression")) {
            return .{ .quantified = try self.parseQuantifiedExpression(node, source) };
        } else if (std.mem.eql(u8, node_type, "parenthesized_predicate")) {
            var cursor = node.walk();
            defer cursor.destroy();

            if (cursor.gotoFirstChild()) {
                while (true) {
                    const child = cursor.node();
                    const child_type = getNodeType(child);

                    if (std.mem.eql(u8, child_type, "predicate")) {
                        const pred = try self.allocator.create(ast.Predicate);
                        pred.* = try self.parsePredicate(child, source);
                        return .{ .parenthesized = pred };
                    }

                    if (!cursor.gotoNextSibling()) break;
                }
            }
        }

        return error.InvalidPredicate;
    }

    fn parseComparison(self: *Parser, node: ts.Node, source: []const u8) !ast.Comparison {
        const left_node = try expectChildByFieldName(node, "left");
        const left = try self.parseExpression(left_node, source);

        const operator_node = try expectChildByFieldName(node, "operator");
        const operator_text = nodeText(operator_node, source);
        const operator = parseComparisonOperator(operator_text);

        const right_node = try expectChildByFieldName(node, "right");
        const right = try self.parseExpression(right_node, source);

        return ast.Comparison{
            .left = left,
            .operator = operator,
            .right = right,
        };
    }

    fn parseComparisonOperator(text: []const u8) ast.ComparisonOperator {
        if (std.mem.eql(u8, text, "=")) return .eq;
        if (std.mem.eql(u8, text, "!=")) return .ne;
        if (std.mem.eql(u8, text, "~")) return .regex_match;
        if (std.mem.eql(u8, text, "!~")) return .regex_not_match;
        if (std.mem.eql(u8, text, ">")) return .gt;
        if (std.mem.eql(u8, text, "<")) return .lt;
        if (std.mem.eql(u8, text, ">=")) return .gte;
        if (std.mem.eql(u8, text, "<=")) return .lte;
        // FIXME: Should error
        return .eq; // default
    }

    fn parseLogicalAnd(self: *Parser, node: ts.Node, source: []const u8) !ast.LogicalAnd {
        const left_node = try expectChildByFieldName(node, "left");
        const left = try self.parsePredicate(left_node, source);

        const right_node = try expectChildByFieldName(node, "right");
        const right = try self.parsePredicate(right_node, source);

        return ast.LogicalAnd{
            .left = left,
            .right = right,
        };
    }

    fn parseLogicalOr(self: *Parser, node: ts.Node, source: []const u8) !ast.LogicalOr {
        const left_node = try expectChildByFieldName(node, "left");
        const left = try self.parsePredicate(left_node, source);

        const right_node = try expectChildByFieldName(node, "right");
        const right = try self.parsePredicate(right_node, source);

        return ast.LogicalOr{
            .left = left,
            .right = right,
        };
    }

    fn parseLogicalNot(self: *Parser, node: ts.Node, source: []const u8) !ast.LogicalNot {
        const pred_node = try expectChildByFieldName(node, "predicate");
        const predicate = try self.parsePredicate(pred_node, source);

        return ast.LogicalNot{
            .predicate = predicate,
        };
    }

    fn parseQuantifiedExpression(self: *Parser, node: ts.Node, source: []const u8) !ast.QuantifiedExpression {
        const quantifier_node = try expectChildByFieldName(node, "quantifier");
        const quantifier_text = nodeText(quantifier_node, source);
        const quantifier: ast.Quantifier = if (std.mem.eql(u8, quantifier_text, "all"))
            .all
        else
            .any;

        const var_node = try expectChildByFieldName(node, "variable");
        const variable = try self.parseVariable(var_node, source);

        const source_node = try expectChildByFieldName(node, "source");
        const nav_source = try self.parseExpression(source_node, source);

        const pred_node = try expectChildByFieldName(node, "predicate");
        const pred = try self.allocator.create(ast.Predicate);
        pred.* = try self.parsePredicate(pred_node, source);

        return ast.QuantifiedExpression{
            .quantifier = quantifier,
            .variable = variable,
            .source = nav_source,
            .predicate = pred,
        };
    }

    // ========================================================================
    // SELECT Clause Parsing
    // ========================================================================

    fn parseSelectClause(self: *Parser, node: ts.Node, source: []const u8) !ast.SelectClause {
        const proj_node = try expectChildByFieldName(node, "projection");
        const projection = try self.parseProjection(proj_node, source);
        return ast.SelectClause{ .projection = projection };
    }

    fn parseProjection(self: *Parser, node: ts.Node, source: []const u8) anyerror!ast.Projection {
        const node_type = getNodeType(node);

        // Handle wrapper projection node
        if (std.mem.eql(u8, node_type, "projection")) {
            // Get the first child which is the actual projection type
            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                return try self.parseProjection(cursor.node(), source);
            }
            return error.InvalidProjection;
        }

        if (std.mem.eql(u8, node_type, "variable")) {
            return .{ .variable = try self.parseVariable(node, source) };
        } else if (std.mem.eql(u8, node_type, "string_literal")) {
            return .{ .string_literal = try self.parseStringLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "regex_literal")) {
            return .{ .regex_literal = try self.parseRegexLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "number_literal")) {
            return .{ .number_literal = try self.parseNumberLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "function_call")) {
            return .{ .function_call = try self.parseFunctionCall(node, source) };
        } else if (std.mem.eql(u8, node_type, "field_access")) {
            const field_access_expr = try self.allocator.create(ast.FieldAccess);
            field_access_expr.* = try self.parseFieldAccess(node, source);
            return .{ .field_access = field_access_expr };
        } else if (std.mem.eql(u8, node_type, "object_literal")) {
            return .{ .object_literal = try self.parseObjectLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "array_literal")) {
            return .{ .array_literal = try self.parseArrayLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "tuple_literal")) {
            return .{ .tuple_literal = try self.parseTupleLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "subquery")) {
            const query_body = try self.allocator.create(ast.QueryBody);
            query_body.* = try self.parseSubquery(node, source);
            return .{ .subquery = query_body };
        }

        return error.InvalidProjection;
    }

    fn parseObjectLiteral(self: *Parser, node: ts.Node, source: []const u8) !ast.ObjectLiteral {
        var fields = std.ArrayList(ast.ObjectField).empty;
        defer fields.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "object_field")) {
                    const field = try self.parseObjectField(child, source);
                    try fields.append(self.allocator, field);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return ast.ObjectLiteral{
            .fields = try fields.toOwnedSlice(self.allocator),
        };
    }

    fn parseObjectField(self: *Parser, node: ts.Node, source: []const u8) !ast.ObjectField {
        // Try to find key and value (full form)
        if (getChildByFieldName(node, "key")) |key_node| {
            const key = try self.allocator.dupe(u8, nodeText(key_node, source));
            const value_node = try expectChildByFieldName(node, "value");
            const value = try self.parseExpression(value_node, source);
            return .{ .key_value = .{ .key = key, .value = value } };
        }

        // Otherwise it's shorthand form (just a variable)
        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "variable")) {
                    return .{ .variable = try self.parseVariable(child, source) };
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return error.InvalidObjectField;
    }

    fn parseArrayLiteral(self: *Parser, node: ts.Node, source: []const u8) !ast.ArrayLiteral {
        var elements = std.ArrayList(ast.Expression).empty;
        defer elements.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "expression")) {
                    const expr = try self.parseExpression(child, source);
                    try elements.append(self.allocator, expr);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return ast.ArrayLiteral{
            .elements = try elements.toOwnedSlice(self.allocator),
        };
    }

    fn parseTupleLiteral(self: *Parser, node: ts.Node, source: []const u8) !ast.TupleLiteral {
        var elements = std.ArrayList(ast.Expression).empty;
        defer elements.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "expression")) {
                    const expr = try self.parseExpression(child, source);
                    try elements.append(self.allocator, expr);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return ast.TupleLiteral{
            .elements = try elements.toOwnedSlice(self.allocator),
        };
    }

    fn parseSubquery(self: *Parser, node: ts.Node, source: []const u8) !ast.QueryBody {
        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                const child_type = getNodeType(child);

                if (std.mem.eql(u8, child_type, "query_body")) {
                    return try self.parseQueryBody(child, source);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return error.InvalidSubquery;
    }

    // ========================================================================
    // Expression Parsing
    // ========================================================================

    fn parseExpression(self: *Parser, node: ts.Node, source: []const u8) anyerror!ast.Expression {
        const node_type = getNodeType(node);

        // Handle wrapper expression node
        if (std.mem.eql(u8, node_type, "expression")) {
            // Get the first child which is the actual expression type
            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                return try self.parseExpression(cursor.node(), source);
            }
            return error.InvalidExpression;
        }

        if (std.mem.eql(u8, node_type, "variable")) {
            return .{ .variable = try self.parseVariable(node, source) };
        } else if (std.mem.eql(u8, node_type, "node_selector")) {
            return .{ .node_selector = try self.parseNodeSelector(node, source) };
        } else if (std.mem.eql(u8, node_type, "string_literal")) {
            return .{ .string_literal = try self.parseStringLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "regex_literal")) {
            return .{ .regex_literal = try self.parseRegexLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "number_literal")) {
            return .{ .number_literal = try self.parseNumberLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "null_literal")) {
            return .null_literal;
        } else if (std.mem.eql(u8, node_type, "field_access")) {
            const field_access = try self.allocator.create(ast.FieldAccess);
            field_access.* = try self.parseFieldAccess(node, source);
            return .{ .field_access = field_access };
        } else if (std.mem.eql(u8, node_type, "child_navigation")) {
            const child_nav = try self.allocator.create(ast.ChildNavigation);
            child_nav.* = try self.parseChildNavigation(node, source);
            return .{ .child_navigation = child_nav };
        } else if (std.mem.eql(u8, node_type, "descendant_navigation")) {
            const desc_nav = try self.allocator.create(ast.DescendantNavigation);
            desc_nav.* = try self.parseDescendantNavigation(node, source);
            return .{ .descendant_navigation = desc_nav };
        } else if (std.mem.eql(u8, node_type, "function_call")) {
            return .{ .function_call = try self.parseFunctionCall(node, source) };
        } else if (std.mem.eql(u8, node_type, "object_literal")) {
            return .{ .object_literal = try self.parseObjectLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "array_literal")) {
            return .{ .array_literal = try self.parseArrayLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "tuple_literal")) {
            return .{ .tuple_literal = try self.parseTupleLiteral(node, source) };
        } else if (std.mem.eql(u8, node_type, "subquery")) {
            const query_body = try self.allocator.create(ast.QueryBody);
            query_body.* = try self.parseSubquery(node, source);
            return .{ .subquery = query_body };
        } else if (std.mem.eql(u8, node_type, "parenthesized_expression")) {
            var cursor = node.walk();
            defer cursor.destroy();

            if (cursor.gotoFirstChild()) {
                while (true) {
                    const child = cursor.node();
                    const child_type = getNodeType(child);

                    if (std.mem.eql(u8, child_type, "expression")) {
                        const inner = try self.allocator.create(ast.Expression);
                        inner.* = try self.parseExpression(child, source);
                        return .{ .parenthesized = inner };
                    }

                    if (!cursor.gotoNextSibling()) break;
                }
            }
            return error.InvalidExpression;
        }

        return error.InvalidExpression;
    }

    fn parseFunctionCall(self: *Parser, node: ts.Node, source: []const u8) !ast.FunctionCall {
        const name_node = try expectChildByFieldName(node, "name");
        const name = try self.allocator.dupe(u8, nodeText(name_node, source));

        var arguments = std.ArrayList(ast.Expression).empty;
        defer arguments.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (cursor.fieldName() != null and std.mem.eql(u8, cursor.fieldName().?, "argument")) {
                    const arg = try self.parseExpression(child, source);
                    try arguments.append(self.allocator, arg);
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return ast.FunctionCall{
            .name = name,
            .arguments = try arguments.toOwnedSlice(self.allocator),
        };
    }

    // ========================================================================
    // Type Parsing
    // ========================================================================

    fn parseType(self: *Parser, node: ts.Node, source: []const u8) error{ OutOfMemory, MissingRequiredField, MissingArrayElementType, MissingObjectValueType }!?ast.Type {
        const node_type = getNodeType(node);

        // Handle wrapper type node
        if (std.mem.eql(u8, node_type, "type")) {
            // Get the first child which is the actual type
            var cursor = node.walk();
            defer cursor.destroy();
            if (cursor.gotoFirstChild()) {
                return try self.parseType(cursor.node(), source);
            }
            return null;
        }

        if (std.mem.eql(u8, node_type, "identifier")) {
            const identifier = try self.allocator.dupe(u8, nodeText(node, source));
            return .{ .identifier = identifier };
        } else if (std.mem.eql(u8, node_type, "builtin_type")) {
            const builtin_text = nodeText(node, source);
            const builtin = parseBuiltinType(builtin_text);
            return .{ .builtin = builtin };
        } else if (std.mem.eql(u8, node_type, "array_type")) {
            return .{ .array = try self.parseArrayType(node, source) };
        } else if (std.mem.eql(u8, node_type, "object_type")) {
            return .{ .object = try self.parseObjectType(node, source) };
        } else if (std.mem.eql(u8, node_type, "tuple_type")) {
            return .{ .tuple = try self.parseTupleType(node, source) };
        } else if (std.mem.eql(u8, node_type, "optional_type")) {
            const base_type_node = try expectChildByFieldName(node, "base_type");
            const base_type = try self.parseType(base_type_node, source);
            if (base_type) |bt| {
                const type_ptr = try self.allocator.create(ast.Type);
                type_ptr.* = bt;
                return .{ .optional = type_ptr };
            }
        }

        return null;
    }

    fn parseBuiltinType(text: []const u8) ast.BuiltinType {
        if (std.mem.eql(u8, text, "string")) return .string;
        if (std.mem.eql(u8, text, "number")) return .number;
        if (std.mem.eql(u8, text, "boolean")) return .boolean;
        if (std.mem.eql(u8, text, "regex")) return .regex;
        return .string; // default
    }

    fn parseArrayType(self: *Parser, node: ts.Node, source: []const u8) !ast.ArrayType {
        const elem_type_node = try expectChildByFieldName(node, "element_type");
        const elem_type = try self.parseType(elem_type_node, source);
        if (elem_type) |et| {
            const type_ptr = try self.allocator.create(ast.Type);
            type_ptr.* = et;
            return ast.ArrayType{ .element_type = type_ptr };
        }
        return error.MissingArrayElementType;
    }

    fn parseObjectType(self: *Parser, node: ts.Node, source: []const u8) !ast.ObjectType {
        const value_type_node = try expectChildByFieldName(node, "value_type");
        const value_type = try self.parseType(value_type_node, source);
        if (value_type) |vt| {
            const type_ptr = try self.allocator.create(ast.Type);
            type_ptr.* = vt;
            return ast.ObjectType{ .value_type = type_ptr };
        }
        return error.MissingObjectValueType;
    }

    fn parseTupleType(self: *Parser, node: ts.Node, source: []const u8) !ast.TupleType {
        var element_types = std.ArrayList(ast.Type).empty;
        defer element_types.deinit(self.allocator);

        var cursor = node.walk();
        defer cursor.destroy();

        if (cursor.gotoFirstChild()) {
            while (true) {
                const child = cursor.node();
                if (cursor.fieldName() != null and std.mem.eql(u8, cursor.fieldName().?, "element_type")) {
                    if (try self.parseType(child, source)) |elem_type| {
                        try element_types.append(self.allocator, elem_type);
                    }
                }

                if (!cursor.gotoNextSibling()) break;
            }
        }

        return ast.TupleType{
            .element_types = try element_types.toOwnedSlice(self.allocator),
        };
    }

    // ========================================================================
    // Literal Parsing
    // ========================================================================

    fn parseStringLiteral(self: *Parser, node: ts.Node, source: []const u8) ![]const u8 {
        const text = nodeText(node, source);
        // Remove quotes and handle escapes
        if (text.len < 2) return error.InvalidStringLiteral;
        const content = text[1 .. text.len - 1];
        return try self.allocator.dupe(u8, content);
    }

    fn parseVariable(self: *Parser, node: ts.Node, source: []const u8) !ast.Variable {
        const text = nodeText(node, source);
        // Remove @ prefix
        if (text.len < 2 or text[0] != '@') return error.InvalidVariable;
        const name = try self.allocator.dupe(u8, text[1..]);
        return ast.Variable{ .name = name };
    }

    fn parseRegexLiteral(self: *Parser, node: ts.Node, source: []const u8) ![]const u8 {
        const text = nodeText(node, source);
        // Remove / delimiters
        if (text.len < 2) return error.InvalidRegexLiteral;
        const pattern = text[1 .. text.len - 1];
        return try self.allocator.dupe(u8, pattern);
    }

    fn parseNumberLiteral(_: *Parser, node: ts.Node, source: []const u8) !f64 {
        const text = nodeText(node, source);
        return std.fmt.parseFloat(f64, text) catch return error.InvalidNumberLiteral;
    }
};

pub const ParseError = error{
    ParserCreationFailed,
    LanguageSetFailed,
    ParseFailed,
    MissingRequiredField,
    InvalidDirective,
    InvalidPredicate,
    InvalidProjection,
    InvalidExpression,
    InvalidObjectField,
    InvalidSubquery,
    InvalidStringLiteral,
    InvalidRegexLiteral,
    InvalidNumberLiteral,
    InvalidVariable,
    MissingArrayElementType,
    MissingObjectValueType,
    OutOfMemory,
};

// ============================================================================
// Tests
// ============================================================================

test "parse simple query" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\query main() {
        \\  from class_declaration as @class
        \\  select @class
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    try std.testing.expect(source_file.items.len == 1);
    try std.testing.expect(source_file.items[0] == .query);

    const query = source_file.items[0].query;
    try std.testing.expectEqualStrings("main", query.name);
    try std.testing.expect(query.parameters.len == 0);
    try std.testing.expect(query.return_type == null);
    try std.testing.expect(query.body.from_clause != null);
    try std.testing.expect(query.body.where_clause == null);
}

test "parse query with where clause" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  where @name = 'Controller'
        \\  select @class
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    try std.testing.expect(source_file.items.len == 1);

    const query = source_file.items[0].query;
    try std.testing.expect(query.body.from_clause.?.bindings.len == 2);
    try std.testing.expect(query.body.where_clause != null);
    try std.testing.expect(query.body.where_clause.?.predicate == .comparison);
}

test "parse query with parameters and return type" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\query find_methods(@class: class_declaration): Array<method_definition> {
        \\  from @class.body > method_definition as @method
        \\  select @method
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    try std.testing.expect(source_file.items.len == 1);

    const query = source_file.items[0].query;
    try std.testing.expectEqualStrings("find_methods", query.name);
    try std.testing.expect(query.parameters.len == 1);
    try std.testing.expectEqualStrings("class", query.parameters[0].name.name);
    try std.testing.expect(query.return_type != null);
    try std.testing.expect(query.return_type.? == .array);
}

test "parse directives" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\#language 'typescript'
        \\
        \\query main() {
        \\  select @result
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    try std.testing.expect(source_file.items.len == 2);
    try std.testing.expect(source_file.items[0] == .directive);
    try std.testing.expect(source_file.items[0].directive == .language);
    try std.testing.expectEqualStrings("typescript", source_file.items[0].directive.language.language);
}

test "parse logical operators" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  where @name = 'Foo' and @name != 'Bar'
        \\  select @class
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    const query = source_file.items[0].query;
    try std.testing.expect(query.body.where_clause.?.predicate == .logical_and);
}

test "parse quantified expression" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const source =
        \\query main() {
        \\  from class_declaration as @class
        \\  where any @m in @class.body > method_definition: @m != null
        \\  select @class
        \\}
    ;

    const source_file = try parser.parse(source);
    defer source_file.deinit(allocator);

    const query = source_file.items[0].query;
    try std.testing.expect(query.body.where_clause.?.predicate == .quantified);
    try std.testing.expect(query.body.where_clause.?.predicate.quantified.quantifier == .any);
    try std.testing.expect(query.body.where_clause.?.predicate.quantified.source == .child_navigation);
}
