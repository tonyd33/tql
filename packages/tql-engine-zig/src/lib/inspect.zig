//! Views of a parsed target and of a grammar's kinds, for writing queries.

const std = @import("std");
const ts = @import("tree-sitter");
const string_literal = @import("lang/string_literal.zig");
const kinds = @import("lang/kinds.zig");

/// One printed node.
pub const Row = struct {
    /// Printed ancestors above this row.
    depth: u32,
    /// The field this node fills in its parent, if any.
    field: ?[]const u8,
    kind: []const u8,
    named: bool,
    missing: bool,
    is_error: bool,
    start_byte: u32,
    end_byte: u32,
    start_point: ts.Point,
    end_point: ts.Point,
    /// The node's source text, set only when no row is printed beneath it.
    text: ?[]const u8,
};

pub const Options = struct {
    /// Omit anonymous tokens.
    named_only: bool = false,
};

/// Append a row for `root` and each node beneath it, in pre-order. `root`
/// is at depth 0 and carries no field.
///
/// Preconditions:
/// - `source` is the text `root`'s tree was parsed from, and outlives `rows`.
pub fn collect(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    root: ts.Node,
    source: []const u8,
    options: Options,
) std.mem.Allocator.Error!void {
    const first = rows.items.len;

    var cursor = root.walk();
    defer cursor.destroy();

    // Whether the node at each cursor level above the current one was printed.
    var printed: std.ArrayList(bool) = .empty;
    defer printed.deinit(gpa);
    var depth: u32 = 0;

    walk: while (true) {
        const node = cursor.node();
        const shown = !options.named_only or node.isNamed();
        if (shown) try rows.append(gpa, .{
            .depth = depth,
            .field = if (printed.items.len == 0) null else cursor.fieldName(),
            .kind = node.kind(),
            .named = node.isNamed(),
            .missing = node.isMissing(),
            .is_error = node.isError(),
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
            .start_point = node.startPoint(),
            .end_point = node.endPoint(),
            .text = null,
        });

        if (cursor.gotoFirstChild()) {
            try printed.append(gpa, shown);
            if (shown) depth += 1;
            continue;
        }
        while (!cursor.gotoNextSibling()) {
            const was_printed = printed.pop() orelse break :walk;
            _ = cursor.gotoParent();
            if (was_printed) depth -= 1;
        }
    }

    const added = rows.items[first..];
    for (added, 0..) |*row, i| {
        const leaf = i + 1 == added.len or added[i + 1].depth <= row.depth;
        if (leaf) row.text = source[row.start_byte..row.end_byte];
    }
}

/// Collect the subtree of every node under `root`, `root` included, whose
/// kind matches one of `kinds`, appending the index of each subtree's first
/// row to `starts`. A match inside another match is collected again as its
/// own subtree.
pub fn collectMatching(
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    starts: *std.ArrayList(usize),
    root: ts.Node,
    source: []const u8,
    wanted: []const u16,
    options: Options,
) std.mem.Allocator.Error!void {
    const language = root.getLanguage();
    var cursor = root.walk();
    defer cursor.destroy();

    var depth: usize = 0;
    while (true) {
        const node = cursor.node();
        for (wanted) |kind| {
            if (!kinds.matches(language, kind, node.kindId())) continue;
            try starts.append(gpa, rows.items.len);
            try collect(gpa, rows, node, source, options);
            break;
        }

        if (cursor.gotoFirstChild()) {
            depth += 1;
            continue;
        }
        while (!cursor.gotoNextSibling()) {
            if (depth == 0) return;
            _ = cursor.gotoParent();
            depth -= 1;
        }
    }
}

/// Column widths that align every range in a set of rows.
pub const Widths = struct {
    row: usize = 1,
    column: usize = 1,

    pub fn of(rows: []const Row) Widths {
        var w: Widths = .{};
        for (rows) |r| {
            w.row = @max(w.row, digits(r.start_point.row + 1), digits(r.end_point.row + 1));
            w.column = @max(w.column, digits(r.start_point.column + 1), digits(r.end_point.column + 1));
        }
        return w;
    }
};

fn digits(n: u32) usize {
    return std.math.log10_int(n) + 1;
}

/// Write one line per row: its range, indentation for its depth, its field,
/// and the node in TQL syntax, followed by its text when it is a leaf.
pub fn writeText(rows: []const Row, widths: Widths, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (rows) |r| {
        try writePoint(r.start_point, widths, w);
        try w.writeAll(" - ");
        try writePoint(r.end_point, widths, w);
        try w.writeAll("  ");
        try w.splatByteAll(' ', 2 * @as(usize, r.depth));
        if (r.field) |f| try w.print("#{s} ", .{f});
        if (r.is_error) {
            try w.writeAll("ERROR");
        } else {
            if (r.missing) try w.writeAll("MISSING ");
            try writeNodeKind(r.named, r.kind, w);
        }
        if (r.text) |t| {
            // An anonymous token's kind already spells its text, unless aliased.
            const redundant = !r.named and !r.is_error and std.mem.eql(u8, t, r.kind);
            if (!r.missing and !redundant) try w.print(" \"{f}\"", .{string_literal.fmt(t)});
        }
        try w.writeByte('\n');
    }
}

fn writePoint(p: ts.Point, widths: Widths, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{[row]d:>[rw]}:{[col]d:<[cw]}", .{
        .row = p.row + 1,
        .rw = widths.row,
        .col = p.column + 1,
        .cw = widths.column,
    });
}

fn writeNodeKind(named: bool, kind: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{f}", .{kinds.Spelled{ .named = named, .name = kind }});
}

/// Write the rows as a JSON array of objects. Positions are zero-based.
pub fn writeJson(rows: []const Row, jws: *std.json.Stringify) std.Io.Writer.Error!void {
    try jws.beginArray();
    for (rows) |r| {
        try jws.beginObject();
        try jws.objectField("depth");
        try jws.write(r.depth);
        try jws.objectField("fieldName");
        try jws.write(r.field);
        try jws.objectField("type");
        try jws.write(r.kind);
        try jws.objectField("isNamed");
        try jws.write(r.named);
        try jws.objectField("isMissing");
        try jws.write(r.missing);
        try jws.objectField("isError");
        try jws.write(r.is_error);
        try jws.objectField("startIndex");
        try jws.write(r.start_byte);
        try jws.objectField("endIndex");
        try jws.write(r.end_byte);
        try jws.objectField("startRow");
        try jws.write(r.start_point.row);
        try jws.objectField("startCol");
        try jws.write(r.start_point.column);
        try jws.objectField("endRow");
        try jws.write(r.end_point.row);
        try jws.objectField("endCol");
        try jws.write(r.end_point.column);
        if (r.text) |t| {
            try jws.objectField("text");
            try jws.write(t);
        }
        try jws.endObject();
    }
    try jws.endArray();
}

pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Write each kind in `ids` on its own line, a supertype marked and followed
/// by its subtypes indented beneath it.
pub fn writeKindList(gpa: std.mem.Allocator, language: *const ts.Language, ids: []const u16, w: *std.Io.Writer) WriteError!void {
    for (ids) |id| {
        try writeKindHeader(language, id, w);
        const covered = try kinds.subtypes(gpa, language, id);
        defer gpa.free(covered);
        for (covered) |subtype| try w.print("  {f}\n", .{kinds.spelled(language, subtype)});
    }
}

fn writeKindHeader(language: *const ts.Language, id: u16, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{f}", .{kinds.spelled(language, id)});
    if (language.nodeKindIsSupertype(id)) try w.writeAll(" (supertype)");
    try w.writeByte('\n');
}

/// Write what the loaded grammar records about one kind: the supertypes that
/// cover it, and a supertype's subtypes.
pub fn writeKind(gpa: std.mem.Allocator, language: *const ts.Language, id: u16, w: *std.Io.Writer) WriteError!void {
    try writeKindHeader(language, id, w);

    var label: []const u8 = "supertypes";
    for (language.supertypes()) |supertype| {
        if (!kinds.covers(language, supertype, id)) continue;
        try w.print("  {s:<12}{f}\n", .{ label, kinds.spelled(language, supertype) });
        label = "";
    }

    const covered = try kinds.subtypes(gpa, language, id);
    defer gpa.free(covered);
    label = "subtypes";
    for (covered) |subtype| {
        try w.print("  {s:<12}{f}\n", .{ label, kinds.spelled(language, subtype) });
        label = "";
    }
}

/// Write one kind as a JSON object: its name, whether it is a supertype, the
/// supertypes that cover it, and its subtypes if it is a supertype.
pub fn writeKindJson(gpa: std.mem.Allocator, language: *const ts.Language, id: u16, jws: *std.json.Stringify) WriteError!void {
    try jws.beginObject();
    try jws.objectField("kind");
    try jws.write(kinds.name(language, id));
    try jws.objectField("supertype");
    try jws.write(language.nodeKindIsSupertype(id));
    try jws.objectField("supertypes");
    try jws.beginArray();
    for (language.supertypes()) |supertype| {
        if (kinds.covers(language, supertype, id)) try jws.write(kinds.name(language, supertype));
    }
    try jws.endArray();
    try jws.objectField("subtypes");
    try jws.beginArray();
    const covered = try kinds.subtypes(gpa, language, id);
    defer gpa.free(covered);
    for (covered) |subtype| try jws.write(kinds.name(language, subtype));
    try jws.endArray();
    try jws.endObject();
}

const Registry = @import("lang/grammar.zig").Registry;

test "matching collects each subtree of a kind, nested ones again" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const l = (try grammars.get("java")).language;

    const source = "class A { class B { int x; } int y; }\n";
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(l);
    const tree = parser.parseString(source, null).?;
    defer tree.destroy();

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    const wanted = [_]u16{l.idForNodeKind("class_declaration", true)};
    try collectMatching(gpa, &rows, &starts, tree.rootNode(), source, &wanted, .{ .named_only = true });

    try std.testing.expectEqual(2, starts.items.len);
    try std.testing.expectEqualStrings("class_declaration", rows.items[starts.items[0]].kind);
    try std.testing.expectEqualStrings("A", rows.items[starts.items[0] + 1].text.?);
    try std.testing.expectEqualStrings("class_declaration", rows.items[starts.items[1]].kind);
    try std.testing.expectEqual(0, rows.items[starts.items[1]].depth);
    try std.testing.expectEqualStrings("B", rows.items[starts.items[1] + 1].text.?);
}

fn expectTree(
    grammar: []const u8,
    source: []const u8,
    options: Options,
    expected: []const u8,
) !void {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get(grammar);

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(g.language);
    const tree = parser.parseString(source, null).?;
    defer tree.destroy();

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try collect(gpa, &rows, tree.rootNode(), source, options);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeText(rows.items, .of(rows.items), &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "text shows every node, with text on leaves only" {
    try expectTree("java",
        \\class A {
        \\    private String s;
        \\}
        \\
    , .{},
        \\1:1  - 4:1   :program
        \\1:1  - 3:2     :class_declaration
        \\1:1  - 1:6       "class"
        \\1:7  - 1:8       #name :identifier "A"
        \\1:9  - 3:2       #body :class_body
        \\1:9  - 1:10        "{"
        \\2:5  - 2:22        :field_declaration
        \\2:5  - 2:12          :modifiers
        \\2:5  - 2:12            "private"
        \\2:13 - 2:19          #type :type_identifier "String"
        \\2:20 - 2:21          #declarator :variable_declarator
        \\2:20 - 2:21            #name :identifier "s"
        \\2:21 - 2:22          ";"
        \\3:1  - 3:2         "}"
        \\
    );
}

test "named only gives a node its text when its children are hidden" {
    try expectTree("java",
        \\class A {
        \\    private String s;
        \\}
        \\
    , .{ .named_only = true },
        \\1:1  - 4:1   :program
        \\1:1  - 3:2     :class_declaration
        \\1:7  - 1:8       #name :identifier "A"
        \\1:9  - 3:2       #body :class_body
        \\2:5  - 2:22        :field_declaration
        \\2:5  - 2:12          :modifiers "private"
        \\2:13 - 2:19          #type :type_identifier "String"
        \\2:20 - 2:21          #declarator :variable_declarator
        \\2:20 - 2:21            #name :identifier "s"
        \\
    );
}

test "rows right-align and columns left-align past one digit" {
    try expectTree("python", "a\n\n\n\n\n\n\n\n\n" ++ "          b\n", .{ .named_only = true },
        \\ 1:1  - 11:1   :module
        \\ 1:1  -  1:2     :identifier "a"
        \\10:11 - 10:12    :identifier "b"
        \\
    );
}

test "a leaf's text is escaped as a string literal" {
    try expectTree("python", "x = \"a\\tb\"\n", .{ .named_only = true },
        \\1:1  - 2:1   :module
        \\1:1  - 1:11    :assignment
        \\1:1  - 1:2       #left :identifier "x"
        \\1:5  - 1:11      #right :string
        \\1:5  - 1:6         :string_start "\""
        \\1:6  - 1:10        :string_content
        \\1:7  - 1:9           :escape_sequence "\\t"
        \\1:10 - 1:11        :string_end "\""
        \\
    );
}

test "error and missing nodes print as tree-sitter names them" {
    try expectTree("java", "class A { int x }\n", .{},
        \\1:1  - 2:1   :program
        \\1:1  - 1:18    :class_declaration
        \\1:1  - 1:6       "class"
        \\1:7  - 1:8       #name :identifier "A"
        \\1:9  - 1:18      #body :class_body
        \\1:9  - 1:10        "{"
        \\1:11 - 1:16        :field_declaration
        \\1:11 - 1:14          #type :integral_type
        \\1:11 - 1:14            "int"
        \\1:15 - 1:16          #declarator :variable_declarator
        \\1:15 - 1:16            #name :identifier "x"
        \\1:16 - 1:16          MISSING ";"
        \\1:17 - 1:18        "}"
        \\
    );
    try expectTree("python", "a = )\n", .{},
        \\1:1 - 2:1  :module
        \\1:1 - 1:6    ERROR
        \\1:1 - 1:2      :identifier "a"
        \\1:3 - 1:4      "="
        \\1:5 - 1:6      ")"
        \\
    );
}

test "a subtree root carries no field" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get("java");

    const source = "class A { String s; }\n";
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(g.language);
    const tree = parser.parseString(source, null).?;
    defer tree.destroy();

    const body = tree.rootNode().child(0).?.childByFieldName("body").?;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try collect(gpa, &rows, body, source, .{ .named_only = true });

    try std.testing.expectEqual(null, rows.items[0].field);
    try std.testing.expectEqual(0, rows.items[0].depth);
    try std.testing.expectEqualStrings("class_body", rows.items[0].kind);
    try std.testing.expectEqual(5, rows.items.len);
}

test "json carries text on leaves only" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get("python");

    const source = "a\n";
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(g.language);
    const tree = parser.parseString(source, null).?;
    defer tree.destroy();

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try collect(gpa, &rows, tree.rootNode(), source, .{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    try writeJson(rows.items, &jws);
    try std.testing.expectEqualStrings(
        \\[{"depth":0,"fieldName":null,"type":"module","isNamed":true,"isMissing":false,"isError":false,"startIndex":0,"endIndex":2,"startRow":0,"startCol":0,"endRow":1,"endCol":0},{"depth":1,"fieldName":null,"type":"identifier","isNamed":true,"isMissing":false,"isError":false,"startIndex":0,"endIndex":1,"startRow":0,"startCol":0,"endRow":0,"endCol":1,"text":"a"}]
    , out.written());
}

test "kind list is sorted, deduplicated, and nests subtypes" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get("python");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const ids = try kinds.named(gpa, g.language);
    defer gpa.free(ids);
    try writeKindList(gpa, g.language, ids, &out.writer);
    const listed = out.written();

    try std.testing.expect(std.mem.indexOf(u8, listed, ":expression_statement (supertype)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, ":expression (supertype)\n  :") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"") == null);
    try std.testing.expectEqual(1, std.mem.count(u8, listed, "\n:identifier\n"));
}

test "a kind shows its supertypes, and a supertype its subtypes" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const g = try grammars.get("python");

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeKind(gpa, g.language, g.language.idForNodeKind("binary_operator", true), &out.writer);
    try std.testing.expectEqualStrings(
        \\:binary_operator
        \\  supertypes  :expression
        \\              :expression_statement
        \\              :primary_expression
        \\
    , out.written());

    out.clearRetainingCapacity();
    try writeKind(gpa, g.language, g.language.idForNodeKind("expression", true), &out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), ":expression (supertype)\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\n  subtypes    :as_pattern\n              :attribute\n") != null);
}
