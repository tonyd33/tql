const std = @import("std");

const SECTION_QUERY = "--- tql ---";
const SECTION_SOURCE = "--- source ---";
const SECTION_SOURCE_TREE = "--- source tree ---";
const SECTION_TQL_TREE = "--- tql tree ---";
const SECTION_BYTECODE = "--- bytecode ---";
const SECTION_VALUES = "--- values ---";
const SECTION_CORE = "--- core ---";
const SECTION_ERROR = "--- error ---";

pub const SectionKind = enum {
    query,
    source,
    source_tree,
    tql_tree,
    bytecode,
    values,
    core,
    @"error",

    pub fn name(self: SectionKind) []const u8 {
        return switch (self) {
            .query => "query",
            .source => "source",
            .source_tree => "source tree",
            .tql_tree => "tql tree",
            .bytecode => "bytecode",
            .values => "values",
            .core => "core",
            .@"error" => "error",
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
            .core => SECTION_CORE,
            .@"error" => SECTION_ERROR,
        };
    }

    /// Parses the name used in `asserts:` and `pending:` headers, which is the
    /// tag name rather than the display name (`source_tree`, not `source tree`).
    pub fn fromTag(s: []const u8) ?SectionKind {
        inline for (comptime std.enums.values(SectionKind)) |kind| {
            if (std.mem.eql(u8, s, @tagName(kind))) return kind;
        }
        return null;
    }
};

/// A set of sections, used for both the ratchet headers and the CLI's
/// `--update` selection.
pub const SectionSet = struct {
    bits: std.EnumSet(SectionKind) = .initEmpty(),

    pub fn has(self: SectionSet, kind: SectionKind) bool {
        return self.bits.contains(kind);
    }

    pub fn add(self: *SectionSet, kind: SectionKind) void {
        self.bits.insert(kind);
    }

    pub fn count(self: SectionSet) usize {
        return self.bits.count();
    }

    /// Parses a comma-separated list of section tag names.
    pub fn parseList(s: []const u8) !SectionSet {
        var set: SectionSet = .{};
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |raw| {
            const tag = std.mem.trim(u8, raw, " \t");
            if (tag.len == 0) continue;
            set.add(SectionKind.fromTag(tag) orelse return error.NoSuchSection);
        }
        return set;
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

/// One corpus case, which is one file. `name` is supplied by the runner from
/// the file's path, not read from the file.
pub const TestCase = struct {
    grammar: []const u8,
    /// Sections this case asserts today. A populated section outside this set
    /// is a defect unless it is listed in `pending`.
    asserts: SectionSet,
    /// Sections written but not yet assertable, each with the reason. These are
    /// counted, not compared, so a hand-written expectation cannot sit inert
    /// without being visible.
    pending: SectionSet,
    pending_reason: []const u8,
    query: Section,
    target: Section,
    /// Optional sections: content.len == 0 means not yet populated.
    source_tree: Section,
    tql_tree: Section,
    bytecode: Section,
    values: Section,
    core: Section,
    /// Expected compile error, as `code at start:end: message` lines. When
    /// present, the case asserts the query is rejected and the sections that
    /// only exist for an accepted query are not compared.
    @"error": Section,

    /// `.source` is stored as `target`, so section lookup cannot go through
    /// `@field` by tag name alone.
    pub fn section(self: TestCase, kind: SectionKind) Section {
        return switch (kind) {
            .query => self.query,
            .source => self.target,
            .source_tree => self.source_tree,
            .tql_tree => self.tql_tree,
            .bytecode => self.bytecode,
            .values => self.values,
            .core => self.core,
            .@"error" => self.@"error",
        };
    }

    pub fn deinit(self: *TestCase, allocator: std.mem.Allocator) void {
        allocator.free(self.grammar);
        allocator.free(self.pending_reason);
        self.query.deinit(allocator);
        self.target.deinit(allocator);
        self.source_tree.deinit(allocator);
        self.tql_tree.deinit(allocator);
        self.bytecode.deinit(allocator);
        self.values.deinit(allocator);
        self.core.deinit(allocator);
        self.@"error".deinit(allocator);
    }
};

pub const CorpusHandle = struct {
    case: TestCase,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CorpusHandle) void {
        self.case.deinit(self.allocator);
        self.allocator.free(self.source);
    }
};

pub const SectionUpdate = struct {
    kind: SectionKind,
    new_content: []const u8,
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

/// Parses one case file. The header is a run of `key: value` lines terminated
/// by the first section marker.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !CorpusHandle {
    const source = try allocator.dupe(u8, content);
    errdefer allocator.free(source);

    var p = Parser.init(source);

    // `grammar` and `pending_reason` are owned here only until `parseSections`
    // takes them; after that the case's own deinit covers them.
    var grammar: ?[]const u8 = null;
    var pending_reason: ?[]const u8 = null;
    var header_owned = true;
    errdefer if (header_owned) {
        if (grammar) |g| allocator.free(g);
        if (pending_reason) |r| allocator.free(r);
    };
    var asserts: SectionSet = .{};
    var pending: SectionSet = .{};

    while (p.peekLine()) |line| {
        if (isSectionMarker(line)) break;
        _ = p.nextLine();

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.MalformedHeader;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "grammar")) {
            if (grammar != null) return error.DuplicateHeader;
            grammar = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "asserts")) {
            asserts = try SectionSet.parseList(value);
        } else if (std.mem.eql(u8, key, "pending")) {
            // `pending: <sections> (<reason>)` — the reason is required so a
            // deferred assertion always records what it is waiting on.
            const open = std.mem.indexOfScalar(u8, value, '(') orelse return error.PendingMissingReason;
            if (!std.mem.endsWith(u8, value, ")")) return error.PendingMissingReason;
            pending = try SectionSet.parseList(value[0..open]);
            const reason = std.mem.trim(u8, value[open + 1 .. value.len - 1], " \t");
            if (reason.len == 0) return error.PendingMissingReason;
            pending_reason = try allocator.dupe(u8, reason);
        } else if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "file") or std.mem.eql(u8, key, "rules")) {
            // `name` is legacy: the path is the name. `file` and `rules` are
            // metadata the runner does not act on.
        } else {
            return error.UnknownHeader;
        }
    }

    const g = grammar orelse return error.MissingGrammar;
    if (pending_reason == null) pending_reason = try allocator.dupe(u8, "");

    header_owned = false;
    var case = try parseSections(allocator, &p, g, asserts, pending, pending_reason.?);
    errdefer case.deinit(allocator);

    try validate(&case);

    return .{
        .case = case,
        .source = source,
        .allocator = allocator,
    };
}

/// A populated section that is neither asserted nor pending is inert: it looks
/// like a specification but nothing checks it. That is the failure this format
/// exists to prevent, so it is an error rather than a warning.
fn validate(case: *const TestCase) !void {
    inline for (comptime std.enums.values(SectionKind)) |kind| {
        if (kind == .query or kind == .source) continue;
        const populated = case.section(kind).content.len > 0;
        if (populated and !case.asserts.has(kind) and !case.pending.has(kind)) {
            return error.UnassertedSection;
        }
        if (case.asserts.has(kind) and case.pending.has(kind)) {
            return error.SectionBothAssertedAndPending;
        }
    }
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

fn parseSections(
    allocator: std.mem.Allocator,
    p: *Parser,
    grammar: []const u8,
    asserts: SectionSet,
    pending: SectionSet,
    pending_reason: []const u8,
) !TestCase {
    // Owned on entry: freed here if the sections fail to parse, since no case
    // exists yet to own them.
    errdefer allocator.free(grammar);
    errdefer allocator.free(pending_reason);

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
    var core: ?Section = null;
    errdefer if (core) |s| s.deinit(allocator);
    var error_section: ?Section = null;
    errdefer if (error_section) |s| s.deinit(allocator);

    while (p.peekLine()) |line| {
        _ = p.nextLine(); // consume the marker line just peeked

        if (std.mem.eql(u8, line, SECTION_QUERY)) {
            query = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_SOURCE)) {
            target = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_SOURCE_TREE)) {
            source_tree = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_TQL_TREE)) {
            tql_tree = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_BYTECODE)) {
            bytecode = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_VALUES)) {
            values = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_CORE)) {
            core = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_ERROR)) {
            error_section = try extractSection(allocator, p);
        } else {
            return error.UnexpectedMarker;
        }
    }

    const here: Section = .{ .content = &.{}, .start = p.pos, .end = p.pos, .content_start = p.pos, .content_end = p.pos };

    return .{
        .grammar = grammar,
        .asserts = asserts,
        .pending = pending,
        .pending_reason = pending_reason,
        .query = query orelse return error.MissingQuery,
        .target = target orelse try dupeSection(allocator, here),
        .source_tree = source_tree orelse try dupeSection(allocator, here),
        .tql_tree = tql_tree orelse try dupeSection(allocator, here),
        .bytecode = bytecode orelse try dupeSection(allocator, here),
        .values = values orelse try dupeSection(allocator, here),
        .core = core orelse try dupeSection(allocator, here),
        .@"error" = error_section orelse try dupeSection(allocator, here),
    };
}

const ALL_SECTION_MARKERS = [_][]const u8{
    SECTION_QUERY,
    SECTION_SOURCE,
    SECTION_SOURCE_TREE,
    SECTION_TQL_TREE,
    SECTION_BYTECODE,
    SECTION_VALUES,
    SECTION_CORE,
    SECTION_ERROR,
};

fn isSectionMarker(line: []const u8) bool {
    for (ALL_SECTION_MARKERS) |marker| {
        if (std.mem.eql(u8, line, marker)) return true;
    }
    return false;
}

/// Extracts section body up to (and not consuming) the next section marker.
/// Records exact byte positions in the source for whitespace preservation.
/// Returns a `Section` with allocated `content` (trimmed).
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

/// Reconstruct the case file with the given section updates applied. Sections
/// not covered by an update are reproduced verbatim from the original source,
/// preserving any whitespace the author added.
///
/// The source layout between section bodies looks like:
///   ...body_end][--- marker ---\n][body_start...
/// Each section's `start`/`end` covers only the body bytes (after the marker's
/// newline, before the next marker line). The marker lines live in the gaps
/// and are emitted verbatim by advancing the cursor through them.
pub fn applyUpdates(
    allocator: std.mem.Allocator,
    handle: CorpusHandle,
    updates: []const SectionUpdate,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const tc = handle.case;
    var cursor: usize = 0;

    // Emitted in source order so the byte gaps line up; a section absent from
    // the file has zero-width bounds at the point it would have appeared.
    const order = [_]SectionKind{
        .query,
        .source,
        .@"error",
        .values,
        .tql_tree,
        .source_tree,
        .bytecode,
        .core,
    };

    var ordered: [order.len]SectionKind = order;
    std.mem.sortUnstable(SectionKind, &ordered, tc, struct {
        fn lt(case: TestCase, a: SectionKind, b: SectionKind) bool {
            return case.section(a).start < case.section(b).start;
        }
    }.lt);

    for (ordered) |kind| {
        cursor = try emitSectionWithGap(
            allocator,
            &buf,
            handle.source,
            kind,
            tc.section(kind),
            findUpdate(updates, kind),
            cursor,
        );
    }

    try buf.appendSlice(allocator, handle.source[cursor..]);

    return buf.toOwnedSlice(allocator);
}

fn findUpdate(updates: []const SectionUpdate, kind: SectionKind) ?[]const u8 {
    for (updates) |u| {
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
    const marker_present = std.mem.endsWith(u8, std.mem.trimEnd(u8, gap, "\n"), kind.marker());
    if (new_content) |nc| {
        if (section.content.len == 0) {
            if (!marker_present) {
                // A synthesized marker must start its own line; the section it
                // follows may have been emitted without a trailing newline.
                if (buf.items.len > 0 and !std.mem.endsWith(u8, buf.items, "\n")) {
                    try buf.append(allocator, '\n');
                }
                try buf.appendSlice(allocator, kind.marker());
                try buf.appendSlice(allocator, "\n");
            }
            try buf.appendSlice(allocator, nc);
            try buf.append(allocator, '\n');
            return section.end;
        }
        // preserve leading whitespace inside the body, replace content, then
        // preserve trailing whitespace
        try buf.appendSlice(allocator, source[section.start..section.content_start]);
        try buf.appendSlice(allocator, nc);
        try buf.appendSlice(allocator, source[section.content_end..section.end]);
        return section.end;
    }
    try buf.appendSlice(allocator, source[section.start..section.end]);
    return section.end;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const FULL_CASE =
    \\grammar: typescript
    \\asserts: values, tql_tree, source_tree, bytecode
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
    try testing.expectEqualStrings("core", SectionKind.core.name());
    try testing.expectEqualStrings("error", SectionKind.@"error".name());
}

test "parse single full case" {
    var corpus = try parse(testing.allocator, FULL_CASE);
    defer corpus.deinit();

    const tc = corpus.case;
    try testing.expectEqualStrings("typescript", tc.grammar);
    try testing.expectEqualStrings(". > foo", tc.query.content);
    try testing.expectEqualStrings("let x = 1;", tc.target.content);
    try testing.expectEqualStrings("(program)", tc.source_tree.content);
    try testing.expectEqualStrings("(source_file .)", tc.tql_tree.content);
    try testing.expectEqualStrings("0000: yield", tc.bytecode.content);
    try testing.expectEqualStrings("[\"hello\"]", tc.values.content);
    try testing.expect(tc.asserts.has(.values));
    try testing.expect(!tc.asserts.has(.core));
}

test "parse case with all optional sections empty yields empty content" {
    const input =
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

    const tc = corpus.case;
    try testing.expectEqualStrings("c", tc.grammar);
    try testing.expectEqualStrings(". > foo", tc.query.content);
    try testing.expectEqualStrings("int x;", tc.target.content);
    try testing.expectEqual(@as(usize, 0), tc.source_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.tql_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.bytecode.content.len);
    try testing.expectEqual(@as(usize, 0), tc.values.content.len);
}

test "parse error on missing grammar header" {
    const input =
        \\notgrammar: typescript
        \\
        \\--- tql ---
        \\. > foo
    ;
    try testing.expectError(error.UnknownHeader, parse(testing.allocator, input));
}

test "parse error when no grammar header is present" {
    const input =
        \\--- tql ---
        \\. > foo
    ;
    try testing.expectError(error.MissingGrammar, parse(testing.allocator, input));
}

test "a populated section that is neither asserted nor pending is rejected" {
    const input =
        \\grammar: typescript
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    try testing.expectError(error.UnassertedSection, parse(testing.allocator, input));
}

test "a pending section is populated but not asserted" {
    const input =
        \\grammar: typescript
        \\pending: values (no evaluator before stage 5)
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expect(corpus.case.pending.has(.values));
    try testing.expect(!corpus.case.asserts.has(.values));
    try testing.expectEqualStrings("no evaluator before stage 5", corpus.case.pending_reason);
}

test "pending without a reason is rejected" {
    const input =
        \\grammar: typescript
        \\pending: values
        \\
        \\--- tql ---
        \\. > foo
    ;
    try testing.expectError(error.PendingMissingReason, parse(testing.allocator, input));
}

test "a section cannot be both asserted and pending" {
    const input =
        \\grammar: typescript
        \\asserts: values
        \\pending: values (contradiction)
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    try testing.expectError(error.SectionBothAssertedAndPending, parse(testing.allocator, input));
}

test "unknown section name in a header is rejected" {
    const input =
        \\grammar: typescript
        \\asserts: nonesuch
        \\
        \\--- tql ---
        \\. > foo
    ;
    try testing.expectError(error.NoSuchSection, parse(testing.allocator, input));
}

test "parse multiline section content" {
    const input =
        \\grammar: typescript
        \\asserts: source_tree, bytecode
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

    const tc = corpus.case;
    try testing.expectEqualStrings("line one\nline two\nline three", tc.target.content);
    try testing.expectEqualStrings("(root\n  (child))", tc.source_tree.content);
    try testing.expectEqualStrings("0000: a\n0001: b", tc.bytecode.content);
    try testing.expectEqual(@as(usize, 0), tc.tql_tree.content.len);
    try testing.expectEqual(@as(usize, 0), tc.values.content.len);
}

test "sections with leading/trailing newlines: content is trimmed" {
    const input =
        \\grammar: typescript
        \\asserts: source_tree, values
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

    try testing.expectEqualStrings("(program)", corpus.case.source_tree.content);
    try testing.expectEqualStrings("[\"trimmed\"]", corpus.case.values.content);
}

test "applyUpdates with no updates reproduces source exactly" {
    var corpus = try parse(testing.allocator, FULL_CASE);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{});
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(FULL_CASE, result);
}

test "applyUpdates preserves whitespace in unchanged sections" {
    const input =
        \\grammar: typescript
        \\asserts: values, tql_tree, source_tree, bytecode
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
        .{ .kind = .bytecode, .new_content = "0000: nop" },
    });
    defer testing.allocator.free(result);

    var updated = try parse(testing.allocator, result);
    defer updated.deinit();

    try testing.expectEqualStrings("(program)", updated.case.source_tree.content);
    try testing.expectEqualStrings("0000: nop", updated.case.bytecode.content);

    // the source_tree body in the output should still contain the surrounding blank lines
    const st = updated.case.source_tree;
    const body = result[st.start..st.end];
    try testing.expect(std.mem.startsWith(u8, body, "\n"));
    try testing.expect(std.mem.endsWith(u8, body, "\n\n"));
}

test "applyUpdates injects a section whose marker is absent" {
    const input =
        \\grammar: typescript
        \\asserts: values
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{ .kind = .core, .new_content = "(pure 1)" },
    });
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, SECTION_CORE) != null);
    try testing.expect(std.mem.indexOf(u8, result, "(pure 1)") != null);
}
