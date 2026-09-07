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

/// A single expected diagnostic. `category` and `span` are normative; the
/// remaining lines of the section are commentary and are never compared, so a
/// diagnostic may be reworded without touching the corpus.
pub const Diagnostic = struct {
    category: []const u8,
    /// Source span as written, or `any` where the location is not a property of
    /// the language.
    span: []const u8,
    commentary: []const u8,
    section: Section,

    pub const SPAN_ANY = "any";

    pub fn spanMatches(self: Diagnostic, actual: []const u8) bool {
        if (std.mem.eql(u8, self.span, SPAN_ANY)) return true;
        return std.mem.eql(u8, self.span, actual);
    }

    pub fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.category);
        allocator.free(self.span);
        allocator.free(self.commentary);
        self.section.deinit(allocator);
    }
};

/// One corpus case, which is one file. `name` is supplied by the runner from
/// the file's path, not read from the file.
pub const TestCase = struct {
    /// One-line summary of what the case pins. The file's path is its identity;
    /// this is what a reader sees next to it.
    title: []const u8,
    grammar: []const u8,
    /// Path the query is run against, for the queries that observe a filename.
    /// Metadata only: no file is read, and `--- source ---` remains the text
    /// parsed. Empty means the query sees no path at all, which is itself
    /// specified behavior.
    file: []const u8,
    /// Prose between the header and the first section. Preserved on update and
    /// never compared: it is where a case explains itself, including why any
    /// section it carries cannot be asserted yet.
    description: Section,
    /// Sections this case asserts today. A populated section outside this set
    /// is a defect unless it is listed in `pending` or `unassertable`.
    asserts: SectionSet,
    /// Sections written but not yet assertable. Counted, not compared, so a
    /// hand-written expectation cannot sit inert without being visible.
    pending: SectionSet,
    /// Sections no implementation can ever assert, because running the query
    /// would not terminate. Excluded from the pending count: these never
    /// resolve, so counting them would put a floor under the budget.
    unassertable: SectionSet,
    query: Section,
    target: Section,
    /// Optional sections: content.len == 0 means not yet populated.
    source_tree: Section,
    tql_tree: Section,
    bytecode: Section,
    values: Section,
    core: Section,
    /// Expected diagnostics, in the order the engine must report them. A case
    /// with any diagnostic asserts the query is rejected, and the sections that
    /// only exist for an accepted query are not compared.
    diagnostics: []Diagnostic,

    /// `.source` is stored as `target`, so section lookup cannot go through
    /// `@field` by tag name alone. `.error` is a list rather than one section;
    /// the first diagnostic stands in for it so callers keyed on `SectionKind`
    /// still see whether the case expects a rejection.
    pub fn section(self: TestCase, kind: SectionKind) Section {
        return switch (kind) {
            .query => self.query,
            .source => self.target,
            .source_tree => self.source_tree,
            .tql_tree => self.tql_tree,
            .bytecode => self.bytecode,
            .values => self.values,
            .core => self.core,
            .@"error" => if (self.diagnostics.len > 0)
                self.diagnostics[0].section
            else
                .{ .content = &.{}, .start = 0, .end = 0, .content_start = 0, .content_end = 0 },
        };
    }

    pub fn expectsError(self: TestCase) bool {
        return self.diagnostics.len > 0;
    }

    /// A section is compared only when the case claims it. `pending` and
    /// `unassertable` sections are written but deliberately unchecked.
    pub fn isAsserted(self: TestCase, kind: SectionKind) bool {
        return self.asserts.has(kind);
    }

    pub fn deinit(self: *TestCase, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.grammar);
        allocator.free(self.file);
        self.description.deinit(allocator);
        self.query.deinit(allocator);
        self.target.deinit(allocator);
        self.source_tree.deinit(allocator);
        self.tql_tree.deinit(allocator);
        self.bytecode.deinit(allocator);
        self.values.deinit(allocator);
        self.core.deinit(allocator);
        for (self.diagnostics) |d| d.deinit(allocator);
        allocator.free(self.diagnostics);
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

    // `title` and `grammar` are owned here only until `parseSections` takes
    // them; after that the case's own deinit covers them.
    var title: ?[]const u8 = null;
    var grammar: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var header_owned = true;
    errdefer if (header_owned) {
        if (title) |t| allocator.free(t);
        if (grammar) |g| allocator.free(g);
        if (file) |f| allocator.free(f);
    };
    var asserts: SectionSet = .{};
    var pending: SectionSet = .{};
    var unassertable: SectionSet = .{};

    // The header runs to the first blank line or section marker; prose after it
    // belongs to the description.
    while (p.peekLine()) |line| {
        if (isSectionMarker(line)) break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) break;
        _ = p.nextLine();

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.MalformedHeader;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "title")) {
            if (title != null) return error.DuplicateHeader;
            title = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "grammar")) {
            if (grammar != null) return error.DuplicateHeader;
            grammar = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "file")) {
            if (file != null) return error.DuplicateHeader;
            file = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "asserts")) {
            asserts = try SectionSet.parseList(value);
        } else if (std.mem.eql(u8, key, "pending")) {
            pending = try SectionSet.parseList(value);
        } else if (std.mem.eql(u8, key, "expect")) {
            // `divergence` is the only expectation that changes what can be
            // asserted: the query never returns, so its outputs are unwitnessable
            // rather than merely unimplemented.
            if (!std.mem.eql(u8, value, "divergence")) return error.UnknownExpectation;
            unassertable.add(.values);
        } else {
            return error.UnknownHeader;
        }
    }

    const g = grammar orelse return error.MissingGrammar;
    const t = title orelse try allocator.dupe(u8, "");
    title = t;
    const f = file orelse try allocator.dupe(u8, "");
    file = f;

    const description = try extractDescription(allocator, &p);
    errdefer description.deinit(allocator);

    header_owned = false;
    var case = try parseSections(allocator, &p, t, g, f, description, asserts, pending, unassertable);
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
        // diagnostics escape the ratchet entirely right now. rejection is
        // exempt from `asserts`/`pending`, so an error expectation cannot be
        // counted as deferred the way a value can.
        // IMPROVE: make the engine reports a category and span of its own.
        // Then, `error` should become an ordinary section and this exemption
        // can go.
        if (kind == .@"error") continue;

        const populated = case.section(kind).content.len > 0;
        const claimed = case.asserts.has(kind) or case.pending.has(kind) or case.unassertable.has(kind);
        if (populated and !claimed) return error.UnassertedSection;

        var claims: usize = 0;
        if (case.asserts.has(kind)) claims += 1;
        if (case.pending.has(kind)) claims += 1;
        if (case.unassertable.has(kind)) claims += 1;
        if (claims > 1) return error.SectionClaimedTwice;
    }
}

/// Consumes everything between the header and the first section marker. This
/// is the case's own explanation of itself and is reproduced verbatim.
fn extractDescription(allocator: std.mem.Allocator, p: *Parser) !Section {
    return extractSection(allocator, p);
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
    title: []const u8,
    grammar: []const u8,
    file: []const u8,
    description: Section,
    asserts: SectionSet,
    pending: SectionSet,
    unassertable: SectionSet,
) !TestCase {
    // Owned on entry: freed here if the sections fail to parse, since no case
    // exists yet to own them.
    errdefer allocator.free(title);
    errdefer allocator.free(grammar);
    errdefer allocator.free(file);
    errdefer description.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |d| d.deinit(allocator);
        diagnostics.deinit(allocator);
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
    var core: ?Section = null;
    errdefer if (core) |s| s.deinit(allocator);

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
            // Repeatable: a case asserting several diagnostics writes one
            // section each, and their order is the order the engine must
            // report them in.
            const s = try extractSection(allocator, p);
            errdefer s.deinit(allocator);
            try diagnostics.append(allocator, try parseDiagnostic(allocator, s));
        } else {
            return error.UnexpectedMarker;
        }
    }

    const here: Section = .{ .content = &.{}, .start = p.pos, .end = p.pos, .content_start = p.pos, .content_end = p.pos };

    return .{
        .title = title,
        .grammar = grammar,
        .file = file,
        .description = description,
        .asserts = asserts,
        .pending = pending,
        .unassertable = unassertable,
        .query = query orelse return error.MissingQuery,
        .target = target orelse try dupeSection(allocator, here),
        .source_tree = source_tree orelse try dupeSection(allocator, here),
        .tql_tree = tql_tree orelse try dupeSection(allocator, here),
        .bytecode = bytecode orelse try dupeSection(allocator, here),
        .values = values orelse try dupeSection(allocator, here),
        .core = core orelse try dupeSection(allocator, here),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

/// Splits an `--- error ---` body into its normative fields and its commentary.
/// `category` and `span` must lead the section, in that order; everything after
/// them is prose the runner never compares.
fn parseDiagnostic(allocator: std.mem.Allocator, s: Section) !Diagnostic {
    var category: ?[]const u8 = null;
    errdefer if (category) |c| allocator.free(c);
    var span: ?[]const u8 = null;
    errdefer if (span) |v| allocator.free(v);

    var rest: []const u8 = s.content;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        const trimmed = std.mem.trim(u8, line, " \t");

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse break;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "category") and category == null and span == null) {
            category = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "span") and category != null and span == null) {
            span = try allocator.dupe(u8, value);
        } else {
            break;
        }

        rest = if (nl) |i| rest[i + 1 ..] else "";
    }

    return .{
        .category = category orelse return error.DiagnosticMissingCategory,
        .span = span orelse return error.DiagnosticMissingSpan,
        .commentary = try allocator.dupe(u8, std.mem.trim(u8, rest, "\n")),
        .section = s,
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
    // `error` is omitted: it is never regenerated, so its bytes are copied as
    // part of the gap preceding whatever follows it.
    const order = [_]SectionKind{
        .query,
        .source,
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
        \\pending: values
        \\
        \\The engine cannot run this query yet, so the values below are written
        \\but unchecked.
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
    try testing.expectEqualStrings("[\"x\"]", corpus.case.values.content);
}

test "a section cannot be both asserted and pending" {
    const input =
        \\grammar: typescript
        \\asserts: values
        \\pending: values
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    try testing.expectError(error.SectionClaimedTwice, parse(testing.allocator, input));
}

test "title and description are parsed and kept apart" {
    const input =
        \\title: `.` is the identity filter
        \\grammar: typescript
        \\asserts: values
        \\
        \\`.` yields its input unchanged. Every navigation chain starts
        \\from it.
        \\
        \\--- tql ---
        \\main = .;
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqualStrings("`.` is the identity filter", corpus.case.title);
    try testing.expectEqualStrings(
        "`.` yields its input unchanged. Every navigation chain starts\nfrom it.",
        corpus.case.description.content,
    );
    try testing.expectEqualStrings("main = .;", corpus.case.query.content);
}

test "a case needs no description" {
    const input =
        \\title: bare
        \\grammar: typescript
        \\
        \\--- tql ---
        \\main = .;
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 0), corpus.case.description.content.len);
}

test "expect: divergence makes values unassertable rather than pending" {
    const input =
        \\title: collecting an infinite filter does not terminate
        \\grammar: typescript
        \\expect: divergence
        \\
        \\Collecting requires materializing every element, so this program does
        \\not terminate. No implementation can assert the values below.
        \\
        \\--- tql ---
        \\main = [nats];
        \\--- source ---
        \\x
        \\--- values ---
        \\["never"]
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expect(corpus.case.unassertable.has(.values));
    try testing.expect(!corpus.case.pending.has(.values));
    try testing.expect(!corpus.case.asserts.has(.values));
}

test "an unknown expectation is rejected" {
    const input =
        \\grammar: typescript
        \\expect: someday
        \\
        \\--- tql ---
        \\main = .;
    ;
    try testing.expectError(error.UnknownExpectation, parse(testing.allocator, input));
}

test "a diagnostic splits into category, span, and commentary" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = double "text";
        \\--- error ---
        \\category: type-mismatch
        \\span: 1:15-1:21
        \\The argument. Expected `int`, found `string`.
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 1), corpus.case.diagnostics.len);
    const d = corpus.case.diagnostics[0];
    try testing.expectEqualStrings("type-mismatch", d.category);
    try testing.expectEqualStrings("1:15-1:21", d.span);
    try testing.expectEqualStrings("The argument. Expected `int`, found `string`.", d.commentary);
    try testing.expect(corpus.case.expectsError());
}

test "span: any matches any reported span" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = .;
        \\--- error ---
        \\category: parse
        \\span: any
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const d = corpus.case.diagnostics[0];
    try testing.expect(d.spanMatches("1:1-1:2"));
    try testing.expect(d.spanMatches(""));
}

test "an exact span matches only itself" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = .;
        \\--- error ---
        \\category: parse
        \\span: 1:1-1:2
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const d = corpus.case.diagnostics[0];
    try testing.expect(d.spanMatches("1:1-1:2"));
    try testing.expect(!d.spanMatches("2:1-2:2"));
}

test "repeated error sections are kept in order" {
    const input =
        \\title: `as` binding is removed
        \\grammar: typescript
        \\asserts: error
        \\
        \\Three names are unresolved, not one.
        \\
        \\--- tql ---
        \\main = . / :class_declaration as c | c.name | text;
        \\--- error ---
        \\category: unresolved-name
        \\span: 1:31-1:33
        \\`as`.
        \\--- error ---
        \\category: unresolved-name
        \\span: 1:34-1:35
        \\`c` as an operand of `as`.
        \\--- error ---
        \\category: unresolved-name
        \\span: 1:38-1:39
        \\`c` in `c.name`.
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expectEqual(@as(usize, 3), corpus.case.diagnostics.len);
    try testing.expectEqualStrings("1:31-1:33", corpus.case.diagnostics[0].span);
    try testing.expectEqualStrings("1:34-1:35", corpus.case.diagnostics[1].span);
    try testing.expectEqualStrings("1:38-1:39", corpus.case.diagnostics[2].span);
}

test "a diagnostic without a category is rejected" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = .;
        \\--- error ---
        \\span: 1:1-1:2
        \\no category above
    ;
    try testing.expectError(error.DiagnosticMissingCategory, parse(testing.allocator, input));
}

test "a diagnostic without a span is rejected" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = .;
        \\--- error ---
        \\category: parse
        \\no span above
    ;
    try testing.expectError(error.DiagnosticMissingSpan, parse(testing.allocator, input));
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
