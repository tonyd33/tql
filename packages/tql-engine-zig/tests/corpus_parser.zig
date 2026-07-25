const std = @import("std");

const SEP = "================================================================================";
const SECTION_QUERY = "--- tql ---";
const SECTION_SOURCE = "--- source ---";
const SECTION_SOURCE_TREE = "--- source tree ---";
const SECTION_TQL_TREE = "--- tql tree ---";
const SECTION_BYTECODE = "--- bytecode ---";
const SECTION_VALUES = "--- values ---";

pub const SectionKind = enum {
    query,
    source,
    source_tree,
    tql_tree,
    bytecode,
    values,

    pub fn name(self: SectionKind) []const u8 {
        return switch (self) {
            .query => "query",
            .source => "source",
            .source_tree => "source tree",
            .tql_tree => "tql tree",
            .bytecode => "bytecode",
            .values => "values",
        };
    }

    pub fn marker(self: SectionKind) []const u8 {
        return switch (self) {
            .query => SECTION_QUERY,
            .source => SECTION_SOURCE,
            .source_tree => SECTION_SOURCE_TREE,
            .tql_tree => SECTION_TQL_TREE,
            .bytecode => SECTION_BYTECODE,
            .values => SECTION_VALUES,
        };
    }
};

/// A parsed section body. `content` is the trimmed text used for comparisons.
/// `start`/`end` are byte offsets in the original source buffer covering the
/// entire section body (after the marker newline, before the next marker line).
/// `content_start`/`content_end` are offsets of just the trimmed content within
/// that body, so the surrounding whitespace can be reproduced verbatim on update.
pub const Section = struct {
    content: []const u8,
    start: usize,
    end: usize,
    content_start: usize,
    content_end: usize,

    pub fn deinit(self: Section, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const TestCase = struct {
    name: []const u8,
    grammar: []const u8,
    query: Section,
    target: Section,
    /// Optional sections: content.len == 0 means not yet populated.
    source_tree: Section,
    tql_tree: Section,
    bytecode: Section,
    values: Section,

    pub fn deinit(self: *TestCase, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.grammar);
        self.query.deinit(allocator);
        self.target.deinit(allocator);
        self.source_tree.deinit(allocator);
        self.tql_tree.deinit(allocator);
        self.bytecode.deinit(allocator);
        self.values.deinit(allocator);
    }
};

pub const CorpusHandle = struct {
    cases: []TestCase,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CorpusHandle) void {
        for (self.cases) |*c| c.deinit(self.allocator);
        self.allocator.free(self.cases);
        self.allocator.free(self.source);
    }
};

pub const SectionUpdate = struct {
    kind: SectionKind,
    new_content: []const u8,
};

pub const UpdateDirective = struct {
    case_name: []const u8,
    sections: []const SectionUpdate,
};

/// Line-based parser that tracks byte positions.
const Parser = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Parser {
        return .{ .src = src, .pos = 0 };
    }

    /// Returns the current line (without trailing '\n') and advances past it.
    /// Returns null at EOF.
    fn nextLine(self: *Parser) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const nl = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n');
        if (nl) |i| {
            self.pos = i + 1;
            return self.src[start..i];
        } else {
            self.pos = self.src.len;
            return self.src[start..];
        }
    }

    /// Peek at the current line without advancing.
    fn peekLine(self: *Parser) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        const nl = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n');
        if (nl) |i| return self.src[self.pos..i];
        return self.src[self.pos..];
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !CorpusHandle {
    const source = try allocator.dupe(u8, content);
    errdefer allocator.free(source);

    var cases: std.ArrayList(TestCase) = .empty;
    errdefer {
        for (cases.items) |*c| c.deinit(allocator);
        cases.deinit(allocator);
    }

    var p = Parser.init(source);

    while (true) {
        const line = p.nextLine() orelse break;
        if (!std.mem.eql(u8, line, SEP)) continue;

        const name_line = p.nextLine() orelse break;
        const sep2 = p.nextLine() orelse break;
        if (!std.mem.eql(u8, sep2, SEP)) continue;

        const grammar_line = p.nextLine() orelse break;
        if (!std.mem.startsWith(u8, grammar_line, "grammar: ")) return error.MissingGrammar;
        const grammar = grammar_line["grammar: ".len..];

        const tc = try parseCase(allocator, &p, name_line, grammar);
        errdefer @constCast(&tc).deinit(allocator);

        for (cases.items) |existing| {
            if (std.mem.eql(u8, existing.name, tc.name)) return error.DuplicateName;
        }

        try cases.append(allocator, tc);
    }

    return .{
        .cases = try cases.toOwnedSlice(allocator),
        .source = source,
        .allocator = allocator,
    };
}

fn dupeSection(allocator: std.mem.Allocator, s: Section) !Section {
    return .{
        .content = try allocator.dupe(u8, s.content),
        .start = s.start,
        .end = s.end,
        .content_start = s.content_start,
        .content_end = s.content_end,
    };
}

fn parseCase(
    allocator: std.mem.Allocator,
    p: *Parser,
    name: []const u8,
    grammar: []const u8,
) !TestCase {
    // advance to --- tql ---
    while (p.nextLine()) |line| {
        if (std.mem.eql(u8, line, SECTION_QUERY)) break;
    }

    var query: ?Section = null;
    errdefer if (query) |s| s.deinit(allocator);
    var target: ?Section = null;
    errdefer if (target) |s| s.deinit(allocator);
    var source_tree: ?Section = null;
    errdefer if (source_tree) |s| s.deinit(allocator);
    var tql_tree: ?Section = null;
    errdefer if (tql_tree) |s| s.deinit(allocator);
    var bytecode: ?Section = null;
    errdefer if (bytecode) |s| s.deinit(allocator);
    var values: ?Section = null;
    errdefer if (values) |s| s.deinit(allocator);

    query = try extractSection(allocator, p);

    while (p.peekLine()) |line| {
        if (std.mem.eql(u8, line, SEP)) break;
        _ = p.nextLine(); // consume the marker line just peeked

        if (std.mem.eql(u8, line, SECTION_SOURCE)) {
            target = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_SOURCE_TREE)) {
            source_tree = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_TQL_TREE)) {
            tql_tree = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_BYTECODE)) {
            bytecode = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_VALUES)) {
            values = try extractSection(allocator, p);
        } else {
            return error.UnexpectedMarker;
        }
    }

    const here: Section = .{ .content = &.{}, .start = p.pos, .end = p.pos, .content_start = p.pos, .content_end = p.pos };

    return .{
        .name = try allocator.dupe(u8, name),
        .grammar = try allocator.dupe(u8, grammar),
        .query = query.?,
        .target = target orelse try dupeSection(allocator, here),
        .source_tree = source_tree orelse try dupeSection(allocator, here),
        .tql_tree = tql_tree orelse try dupeSection(allocator, here),
        .bytecode = bytecode orelse try dupeSection(allocator, here),
        .values = values orelse try dupeSection(allocator, here),
    };
}

const ALL_SECTION_MARKERS = [_][]const u8{
    SECTION_QUERY,
    SECTION_SOURCE,
    SECTION_SOURCE_TREE,
    SECTION_TQL_TREE,
    SECTION_BYTECODE,
    SECTION_VALUES,
    SEP,
};

fn isSectionMarker(line: []const u8) bool {
    for (ALL_SECTION_MARKERS) |marker| {
        if (std.mem.eql(u8, line, marker)) return true;
    }
    return false;
}

/// Extracts section body up to (and not consuming) the next section marker
/// or SEP. Records exact byte positions in the source for whitespace
/// preservation. Returns a `Section` with allocated `content` (trimmed).
fn extractSection(
    allocator: std.mem.Allocator,
    p: *Parser,
) !Section {
    const body_start = p.pos;

    // find end of body by peeking ahead
    var body_end = body_start;
    while (p.peekLine()) |line| {
        if (isSectionMarker(line)) {
            body_end = p.pos;
            break;
        }
        _ = p.nextLine();
        body_end = p.pos;
    } else {
        body_end = p.pos;
    }

    const body = p.src[body_start..body_end];

    // find trimmed content bounds within body
    const trimmed = std.mem.trim(u8, body, "\n");
    const content_start = if (trimmed.len > 0)
        body_start + (std.mem.indexOf(u8, body, trimmed) orelse 0)
    else
        body_start;
    const content_end = content_start + trimmed.len;

    return .{
        .content = try allocator.dupe(u8, trimmed),
        .start = body_start,
        .end = body_end,
        .content_start = content_start,
        .content_end = content_end,
    };
}

/// Reconstruct the corpus file, applying updates from directives. Sections not
/// covered by a directive are reproduced verbatim from the original source
/// (preserving any whitespace the user added). Returns an owned `[]u8`.
///
/// The source layout between section bodies looks like:
///   ...body_end][--- marker ---\n][body_start...
/// Each section's `start`/`end` covers only the body bytes (after the marker's
/// newline, before the next marker line). The marker lines live in the gaps
/// and are emitted verbatim by advancing the cursor through them.
pub fn applyUpdates(
    allocator: std.mem.Allocator,
    handle: CorpusHandle,
    directives: []const UpdateDirective,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var dir_map: std.StringHashMap([]const SectionUpdate) = .init(allocator);
    defer dir_map.deinit();
    for (directives) |d| try dir_map.put(d.case_name, d.sections);

    var cursor: usize = 0;

    for (handle.cases) |tc| {
        const case_updates = dir_map.get(tc.name);

        // Emit everything from cursor up through each section body.
        // The gaps between bodies (marker lines, grammar line, blank lines)
        // are copied verbatim as part of source[cursor..section.start].
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .query, tc.query, null, cursor);
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .source, tc.target, null, cursor);
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .values, tc.values, findUpdate(case_updates, .values), cursor);
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .tql_tree, tc.tql_tree, findUpdate(case_updates, .tql_tree), cursor);
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .source_tree, tc.source_tree, findUpdate(case_updates, .source_tree), cursor);
        cursor = try emitSectionWithGap(allocator, &buf, handle.source, .bytecode, tc.bytecode, findUpdate(case_updates, .bytecode), cursor);
    }

    // emit trailing content (inter-case gaps, EOF)
    try buf.appendSlice(allocator, handle.source[cursor..]);

    return buf.toOwnedSlice(allocator);
}

fn findUpdate(updates: ?[]const SectionUpdate, kind: SectionKind) ?[]const u8 {
    const list = updates orelse return null;
    for (list) |u| {
        if (u.kind == kind) return u.new_content;
    }
    return null;
}

/// Emits source[cursor..section.start] (the gap = marker line) verbatim, then
/// emits the section body either verbatim or with substituted content.
/// When section.content is empty and new_content is provided, the new content
/// is injected (with a trailing newline) in place of the empty body. If the
/// section's own marker never appeared in the source (a brand-new optional
/// section on a freshly-authored test case), the marker line is synthesized.
fn emitSectionWithGap(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    source: []const u8,
    kind: SectionKind,
    section: Section,
    new_content: ?[]const u8,
    cursor: usize,
) !usize {
    // emit the gap (marker line + any inter-section bytes)
    const gap = source[cursor..section.start];
    try buf.appendSlice(allocator, gap);
    const marker_present = std.mem.endsWith(u8, source[0..section.start], kind.marker());
    if (new_content) |nc| {
        if (section.content.len == 0) {
            if (!marker_present) {
                try buf.appendSlice(allocator, kind.marker());
                try buf.appendSlice(allocator, "\n");
            } else if (gap.len > 0 and !std.mem.endsWith(u8, gap, "\n")) {
                // empty body: inject new content with newline. The marker's own
                // newline may be absent if it was the last line in the file.
                try buf.appendSlice(allocator, "\n");
            }
            try buf.appendSlice(allocator, nc);
            try buf.appendSlice(allocator, "\n");
        } else {
            // preserve surrounding whitespace, substitute trimmed content
            try buf.appendSlice(allocator, source[section.start..section.content_start]);
            try buf.appendSlice(allocator, nc);
            try buf.appendSlice(allocator, source[section.content_end..section.end]);
        }
    } else {
        try buf.appendSlice(allocator, source[section.start..section.end]);
    }
    return section.end;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const FULL_CASE =
    \\================================================================================
    \\my test case
    \\================================================================================
    \\grammar: typescript
    \\
    \\--- tql ---
    \\. > foo
    \\--- source ---
    \\let x = 1;
    \\--- values ---
    \\["hello"]
    \\--- tql tree ---
    \\(source_file .)
    \\--- source tree ---
    \\(program)
    \\--- bytecode ---
    \\0000: yield
;

test "SectionKind.name returns correct strings" {
    try testing.expectEqualStrings("query", SectionKind.query.name());
    try testing.expectEqualStrings("source", SectionKind.source.name());
    try testing.expectEqualStrings("source tree", SectionKind.source_tree.name());
    try testing.expectEqualStrings("tql tree", SectionKind.tql_tree.name());
    try testing.expectEqualStrings("bytecode", SectionKind.bytecode.name());
    try testing.expectEqualStrings("values", SectionKind.values.name());
}

test "parse empty content yields zero cases" {
    var corpus = try parse(testing.allocator, "");
    defer corpus.deinit();
    try testing.expectEqual(@as(usize, 0), corpus.cases.len);
}

test "parse content with no valid separator yields zero cases" {
    var corpus = try parse(testing.allocator, "just some random text\nno separators here\n");
    defer corpus.deinit();
    try testing.expectEqual(@as(usize, 0), corpus.cases.len);
}

test "parse single full case" {
    var corpus = try parse(testing.allocator, FULL_CASE);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 1), corpus.cases.len);
    const tc = corpus.cases[0];

    try testing.expectEqualStrings("my test case", tc.name);
    try testing.expectEqualStrings("typescript", tc.grammar);
    try testing.expectEqualStrings(". > foo", tc.query.content);
    try testing.expectEqualStrings("let x = 1;", tc.target.content);
    try testing.expectEqualStrings("(program)", tc.source_tree.content);
    try testing.expectEqualStrings("(source_file .)", tc.tql_tree.content);
    try testing.expectEqualStrings("0000: yield", tc.bytecode.content);
    try testing.expectEqualStrings("[\"hello\"]", tc.values.content);
}

test "parse case with all optional sections empty yields empty content" {
    const input =
        \\================================================================================
        \\empty sections case
        \\================================================================================
        \\grammar: c
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\int x;
        \\--- source tree ---
        \\--- tql tree ---
        \\--- bytecode ---
        \\--- values ---
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 1), corpus.cases.len);
    const tc = corpus.cases[0];

    try testing.expectEqualStrings("empty sections case", tc.name);
    try testing.expectEqualStrings("c", tc.grammar);
    try testing.expectEqualStrings(". > foo", tc.query.content);
    try testing.expectEqualStrings("int x;", tc.target.content);
    try testing.expectEqual(@as(usize, 0), tc.source_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.tql_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.bytecode.content.len);
    try testing.expectEqual(@as(usize, 0), tc.values.content.len);
}

test "parse multiple cases" {
    const input =
        \\================================================================================
        \\case one
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\query1
        \\--- source ---
        \\source1
        \\--- source tree ---
        \\tree1
        \\--- tql tree ---
        \\--- bytecode ---
        \\--- values ---
        \\
        \\================================================================================
        \\case two
        \\================================================================================
        \\grammar: c
        \\
        \\--- tql ---
        \\query2
        \\--- source ---
        \\source2
        \\--- source tree ---
        \\--- tql tree ---
        \\tql2
        \\--- bytecode ---
        \\--- values ---
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 2), corpus.cases.len);

    try testing.expectEqualStrings("case one", corpus.cases[0].name);
    try testing.expectEqualStrings("typescript", corpus.cases[0].grammar);
    try testing.expectEqualStrings("query1", corpus.cases[0].query.content);
    try testing.expectEqualStrings("source1", corpus.cases[0].target.content);
    try testing.expectEqualStrings("tree1", corpus.cases[0].source_tree.content);
    try testing.expectEqual(@as(usize, 0), corpus.cases[0].tql_tree.content.len);

    try testing.expectEqualStrings("case two", corpus.cases[1].name);
    try testing.expectEqualStrings("c", corpus.cases[1].grammar);
    try testing.expectEqualStrings("query2", corpus.cases[1].query.content);
    try testing.expectEqualStrings("source2", corpus.cases[1].target.content);
    try testing.expectEqual(@as(usize, 0), corpus.cases[1].source_tree.content.len);
    try testing.expectEqualStrings("tql2", corpus.cases[1].tql_tree.content);
}

test "parse error on missing grammar prefix" {
    const input =
        \\================================================================================
        \\bad case
        \\================================================================================
        \\notgrammar: typescript
    ;
    try testing.expectError(error.MissingGrammar, parse(testing.allocator, input));
}

test "parse duplicate case name returns error" {
    const input =
        \\================================================================================
        \\same name
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- source tree ---
        \\--- tql tree ---
        \\--- bytecode ---
        \\--- values ---
        \\
        \\================================================================================
        \\same name
        \\================================================================================
        \\grammar: c
        \\
        \\--- tql ---
        \\. > bar
        \\--- source ---
        \\y
        \\--- source tree ---
        \\--- tql tree ---
        \\--- bytecode ---
        \\--- values ---
    ;
    try testing.expectError(error.DuplicateName, parse(testing.allocator, input));
}

test "parse multiline section content" {
    const input =
        \\================================================================================
        \\multiline case
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\line one
        \\line two
        \\line three
        \\--- source tree ---
        \\(root
        \\  (child))
        \\--- tql tree ---
        \\--- bytecode ---
        \\0000: a
        \\0001: b
        \\--- values ---
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 1), corpus.cases.len);
    const tc = corpus.cases[0];
    try testing.expectEqualStrings("line one\nline two\nline three", tc.target.content);
    try testing.expectEqualStrings("(root\n  (child))", tc.source_tree.content);
    try testing.expectEqualStrings("0000: a\n0001: b", tc.bytecode.content);
    try testing.expectEqual(@as(usize, 0), tc.tql_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.values.content.len);
}

test "sections with leading/trailing newlines: content is trimmed" {
    const input =
        \\================================================================================
        \\trim test
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\the source
        \\--- source tree ---
        \\
        \\(program)
        \\
        \\--- tql tree ---
        \\--- bytecode ---
        \\--- values ---
        \\
        \\["trimmed"]
        \\
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 1), corpus.cases.len);
    const tc = corpus.cases[0];
    try testing.expectEqualStrings("(program)", tc.source_tree.content);
    try testing.expectEqualStrings("[\"trimmed\"]", tc.values.content);
}

test "applyUpdates with no directives reproduces source exactly" {
    var corpus = try parse(testing.allocator, FULL_CASE);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{});
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(FULL_CASE, result);
}

test "applyUpdates preserves whitespace in unchanged sections" {
    const input =
        \\================================================================================
        \\ws test
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
        \\--- tql tree ---
        \\(source_file .)
        \\--- source tree ---
        \\
        \\(program)
        \\
        \\--- bytecode ---
        \\0000: yield
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    // update only bytecode; source_tree whitespace must be preserved
    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{
            .case_name = "ws test",
            .sections = &.{
                .{ .kind = .bytecode, .new_content = "0000: nop" },
            },
        },
    });
    defer testing.allocator.free(result);

    var updated = try parse(testing.allocator, result);
    defer updated.deinit();

    try testing.expectEqualStrings("(program)", updated.cases[0].source_tree.content);
    try testing.expectEqualStrings("0000: nop", updated.cases[0].bytecode.content);

    // the source_tree body in the output should still contain the surrounding blank lines
    const st = updated.cases[0].source_tree;
    const body = result[st.start..st.end];
    try testing.expect(std.mem.startsWith(u8, body, "\n"));
    try testing.expect(std.mem.endsWith(u8, body, "\n\n"));
}

test "applyUpdates updating section content preserves its own surrounding whitespace" {
    const input =
        \\================================================================================
        \\ws update test
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
        \\--- tql tree ---
        \\--- source tree ---
        \\--- bytecode ---
        \\
        \\0000: old
        \\
        \\
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{
            .case_name = "ws update test",
            .sections = &.{
                .{ .kind = .bytecode, .new_content = "0000: new" },
            },
        },
    });
    defer testing.allocator.free(result);

    var updated = try parse(testing.allocator, result);
    defer updated.deinit();

    try testing.expectEqualStrings("0000: new", updated.cases[0].bytecode.content);

    // surrounding blank lines around bytecode should be preserved
    const bc = updated.cases[0].bytecode;
    const body = result[bc.start..bc.end];
    try testing.expect(std.mem.startsWith(u8, body, "\n"));
    try testing.expect(std.mem.endsWith(u8, body, "\n\n"));
}

test "applyUpdates populating a null section uses newline terminator" {
    const input =
        \\================================================================================
        \\new section test
        \\================================================================================
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\--- tql tree ---
        \\--- source tree ---
        \\--- bytecode ---
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 0), corpus.cases[0].bytecode.content.len);

    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{
            .case_name = "new section test",
            .sections = &.{
                .{ .kind = .bytecode, .new_content = "0000: yield" },
            },
        },
    });
    defer testing.allocator.free(result);

    var updated = try parse(testing.allocator, result);
    defer updated.deinit();

    try testing.expectEqualStrings("0000: yield", updated.cases[0].bytecode.content);
}
