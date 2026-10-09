const std = @import("std");

const SECTION_QUERY = "--- tql ---";
const SECTION_SOURCE = "--- source ---";
const SECTION_SOURCE_TREE = "--- source tree ---";
const SECTION_TQL_TREE = "--- tql tree ---";
const SECTION_VALUES = "--- values ---";
const SECTION_RUNTIME_ERROR = "--- runtime error ---";
const SECTION_CORE = "--- core ---";
const SECTION_SIMPLIFIED = "--- simplified ---";
const SECTION_STG = "--- stg ---";
const SECTION_TYPES = "--- types ---";
const SECTION_ERROR = "--- error ---";

pub const SectionKind = enum {
    query,
    source,
    source_tree,
    tql_tree,
    values,
    runtime_error,
    core,
    simplified,
    stg,
    types,
    @"error",

    pub fn name(self: SectionKind) []const u8 {
        return switch (self) {
            .query => "query",
            .source => "source",
            .source_tree => "source tree",
            .tql_tree => "tql tree",
            .values => "values",
            .runtime_error => "runtime error",
            .core => "core",
            .simplified => "simplified",
            .stg => "stg",
            .types => "types",
            .@"error" => "error",
        };
    }

    pub fn marker(self: SectionKind) []const u8 {
        return switch (self) {
            .query => SECTION_QUERY,
            .source => SECTION_SOURCE,
            .source_tree => SECTION_SOURCE_TREE,
            .tql_tree => SECTION_TQL_TREE,
            .values => SECTION_VALUES,
            .runtime_error => SECTION_RUNTIME_ERROR,
            .core => SECTION_CORE,
            .simplified => SECTION_SIMPLIFIED,
            .stg => SECTION_STG,
            .types => SECTION_TYPES,
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
    /// Whether the file has this section's marker. An absent section has
    /// zero-width bounds at the end of the file.
    present: bool = true,

    pub fn deinit(self: Section, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
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
    /// is a defect unless it is listed in `pending`.
    asserts: SectionSet,
    /// Sections written but not yet assertable. Counted, not compared, so a
    /// hand-written expectation cannot sit inert without being visible.
    pending: SectionSet,
    query: Section,
    target: Section,
    /// Modules the query may import, each from a `--- module Name ---`
    /// section. Input, never compared.
    modules: []const Module,
    /// Optional sections: content.len == 0 means not yet populated.
    source_tree: Section,
    tql_tree: Section,
    values: Section,
    /// The name of the error evaluation stops with. A case asserting one
    /// expects the query to compile and then fail at runtime.
    runtime_error: Section,
    core: Section,
    /// The entry module's Core after checking and `core_to_core`.
    simplified: Section,
    /// The entry module's definitions translated to STG, after `core_to_core`.
    stg: Section,
    /// The inferred scheme of each entry-module definition, in declaration
    /// order. Independent of `core`: a program has an untyped Core term
    /// whether or not it typechecks.
    types: Section,
    /// Every diagnostic the engine must report, in order, rendered as the CLI
    /// prints them. A case asserting one expects the query to be rejected, and
    /// the sections that only exist for an accepted query are not compared.
    @"error": Section,

    /// `.source` is stored as `target`, so section lookup cannot go through
    /// `@field` by tag name alone.
    pub fn section(self: TestCase, kind: SectionKind) Section {
        return switch (kind) {
            .query => self.query,
            .source => self.target,
            .source_tree => self.source_tree,
            .tql_tree => self.tql_tree,
            .values => self.values,
            .runtime_error => self.runtime_error,
            .core => self.core,
            .simplified => self.simplified,
            .stg => self.stg,
            .types => self.types,
            .@"error" => self.@"error",
        };
    }

    pub fn expectsError(self: TestCase) bool {
        return self.asserts.has(.@"error") or self.@"error".content.len > 0;
    }

    /// A section is compared only when the case claims it. `pending` sections
    /// are written but deliberately unchecked.
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
        for (self.modules) |m| m.deinit(allocator);
        allocator.free(self.modules);
        self.source_tree.deinit(allocator);
        self.tql_tree.deinit(allocator);
        self.values.deinit(allocator);
        self.runtime_error.deinit(allocator);
        self.core.deinit(allocator);
        self.simplified.deinit(allocator);
        self.stg.deinit(allocator);
        self.types.deinit(allocator);
        self.@"error".deinit(allocator);
    }
};

/// A module source a case supplies to the query.
pub const Module = struct {
    name: []const u8,
    text: Section,

    pub fn deinit(self: Module, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.text.deinit(allocator);
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

    header_owned = false;
    var case = try parseSections(allocator, &p, t, g, f, description, asserts, pending);
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
        const claimed = case.asserts.has(kind) or case.pending.has(kind);
        if (populated and !claimed) return error.UnassertedSection;

        if (case.asserts.has(kind) and case.pending.has(kind)) return error.SectionClaimedTwice;
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
        .present = s.present,
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
) !TestCase {
    // Owned on entry: freed here if the sections fail to parse, since no case
    // exists yet to own them.
    errdefer allocator.free(title);
    errdefer allocator.free(grammar);
    errdefer allocator.free(file);
    errdefer description.deinit(allocator);

    var query: ?Section = null;
    errdefer if (query) |s| s.deinit(allocator);
    var target: ?Section = null;
    errdefer if (target) |s| s.deinit(allocator);
    var source_tree: ?Section = null;
    errdefer if (source_tree) |s| s.deinit(allocator);
    var tql_tree: ?Section = null;
    errdefer if (tql_tree) |s| s.deinit(allocator);
    var values: ?Section = null;
    errdefer if (values) |s| s.deinit(allocator);
    var runtime_error: ?Section = null;
    errdefer if (runtime_error) |s| s.deinit(allocator);
    var core: ?Section = null;
    errdefer if (core) |s| s.deinit(allocator);
    var simplified: ?Section = null;
    errdefer if (simplified) |s| s.deinit(allocator);
    var stg: ?Section = null;
    errdefer if (stg) |s| s.deinit(allocator);
    var types: ?Section = null;
    errdefer if (types) |s| s.deinit(allocator);
    var err: ?Section = null;
    errdefer if (err) |s| s.deinit(allocator);
    var modules: std.ArrayList(Module) = .empty;
    errdefer {
        for (modules.items) |m| m.deinit(allocator);
        modules.deinit(allocator);
    }

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
        } else if (std.mem.eql(u8, line, SECTION_VALUES)) {
            values = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_RUNTIME_ERROR)) {
            runtime_error = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_CORE)) {
            core = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_SIMPLIFIED)) {
            simplified = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_STG)) {
            stg = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_TYPES)) {
            types = try extractSection(allocator, p);
        } else if (std.mem.eql(u8, line, SECTION_ERROR)) {
            err = try extractSection(allocator, p);
        } else if (moduleMarkerName(line)) |name| {
            const owned = try allocator.dupe(u8, name);
            errdefer allocator.free(owned);
            const text = try extractSection(allocator, p);
            errdefer text.deinit(allocator);
            try modules.append(allocator, .{ .name = owned, .text = text });
        } else {
            return error.UnexpectedMarker;
        }
    }

    const here: Section = .{
        .content = &.{},
        .start = p.pos,
        .end = p.pos,
        .content_start = p.pos,
        .content_end = p.pos,
        .present = false,
    };

    return .{
        .title = title,
        .grammar = grammar,
        .file = file,
        .description = description,
        .asserts = asserts,
        .pending = pending,
        .query = query orelse return error.MissingQuery,
        .modules = try modules.toOwnedSlice(allocator),
        .target = target orelse try dupeSection(allocator, here),
        .source_tree = source_tree orelse try dupeSection(allocator, here),
        .tql_tree = tql_tree orelse try dupeSection(allocator, here),
        .values = values orelse try dupeSection(allocator, here),
        .runtime_error = runtime_error orelse try dupeSection(allocator, here),
        .core = core orelse try dupeSection(allocator, here),
        .simplified = simplified orelse try dupeSection(allocator, here),
        .stg = stg orelse try dupeSection(allocator, here),
        .types = types orelse try dupeSection(allocator, here),
        .@"error" = err orelse try dupeSection(allocator, here),
    };
}

const ALL_SECTION_MARKERS = [_][]const u8{
    SECTION_QUERY,
    SECTION_SOURCE,
    SECTION_SOURCE_TREE,
    SECTION_TQL_TREE,
    SECTION_VALUES,
    SECTION_RUNTIME_ERROR,
    SECTION_CORE,
    SECTION_SIMPLIFIED,
    SECTION_STG,
    SECTION_TYPES,
    SECTION_ERROR,
};

fn isSectionMarker(line: []const u8) bool {
    for (ALL_SECTION_MARKERS) |marker| {
        if (std.mem.eql(u8, line, marker)) return true;
    }
    return moduleMarkerName(line) != null;
}

/// `Name` when `line` is `--- module Name ---`.
fn moduleMarkerName(line: []const u8) ?[]const u8 {
    const rest = std.mem.cutPrefix(u8, line, "--- module ") orelse return null;
    const name = std.mem.cutSuffix(u8, rest, " ---") orelse return null;
    return if (name.len == 0) null else name;
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
        .values,
        .runtime_error,
        .tql_tree,
        .source_tree,
        .core,
        .simplified,
        .stg,
        .types,
        .@"error",
    };

    var ordered: [order.len]SectionKind = order;
    std.mem.sortUnstable(SectionKind, &ordered, tc, struct {
        fn lt(case: TestCase, a: SectionKind, b: SectionKind) bool {
            const x = case.section(a);
            const y = case.section(b);
            // An absent section at the end of the file must not claim the
            // gap holding a present section's marker.
            if (x.start == y.start) return x.present and !y.present;
            return x.start < y.start;
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
                if (buf.items.len > 0) {
                    if (!std.mem.endsWith(u8, buf.items, "\n")) {
                        try buf.append(allocator, '\n');
                    }
                    if (!std.mem.endsWith(u8, buf.items, "\n\n")) {
                        try buf.append(allocator, '\n');
                    }
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
        \\--- core ---
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
    try testing.expectEqual(@as(usize, 0), tc.core.content.len);
    try testing.expectEqual(@as(usize, 0), tc.values.content.len);
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

test "a pending error section still expects a rejection" {
    const input =
        \\grammar: typescript
        \\pending: error
        \\
        \\--- tql ---
        \\main = double "text";
        \\--- error ---
        \\error[type-mismatch]: Expected `Int`, found `String`.
        \\ --> 1:15
        \\  |
        \\1 | main = double "text";
        \\  |               ^^^^^^
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expect(corpus.case.expectsError());
    try testing.expect(!corpus.case.isAsserted(.@"error"));
}

test "an unknown header is rejected" {
    const input =
        \\grammar: typescript
        \\expect: divergence
        \\
        \\--- tql ---
        \\main = arr identity;
    ;
    try testing.expectError(error.UnknownHeader, parse(testing.allocator, input));
}

test "an asserted error section with no content still expects a rejection" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = x;
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    try testing.expect(corpus.case.expectsError());
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

test "applyUpdates with no updates reproduces source exactly" {
    const input =
        \\title: a full case
        \\grammar: typescript
        \\asserts: values, tql_tree, source_tree, core
        \\
        \\A description paragraph
        \\over two lines.
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
        \\--- core ---
        \\children
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{});
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(input, result);
}

test "applyUpdates rewrites the error section" {
    const input =
        \\grammar: typescript
        \\asserts: error, tql_tree
        \\
        \\--- tql ---
        \\main = x;
        \\--- error ---
        \\error[parse]: Unexpected `x`.
        \\
        \\--- tql tree ---
        \\(source_file)
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{ .kind = .@"error", .new_content = "error[unresolved-name]: `x` is not defined." },
        .{ .kind = .tql_tree, .new_content = "(source_file x)" },
    });
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(
        \\grammar: typescript
        \\asserts: error, tql_tree
        \\
        \\--- tql ---
        \\main = x;
        \\--- error ---
        \\error[unresolved-name]: `x` is not defined.
        \\
        \\--- tql tree ---
        \\(source_file x)
    , result);
}

test "applyUpdates fills an empty section at the end of the file" {
    const input =
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = x;
        \\
        \\--- error ---
        \\
    ;
    var corpus = try parse(testing.allocator, input);
    defer corpus.deinit();

    const result = try applyUpdates(testing.allocator, corpus, &.{
        .{ .kind = .@"error", .new_content = "error[unresolved-name]: `x` is not defined." },
    });
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(
        \\grammar: typescript
        \\asserts: error
        \\
        \\--- tql ---
        \\main = x;
        \\
        \\--- error ---
        \\error[unresolved-name]: `x` is not defined.
        \\
    , result);
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

    try testing.expectEqualStrings(
        \\grammar: typescript
        \\asserts: values
        \\
        \\--- tql ---
        \\. > foo
        \\--- source ---
        \\x
        \\--- values ---
        \\["x"]
        \\
        \\--- core ---
        \\(pure 1)
        \\
    , result);
}
