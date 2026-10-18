//! What a grammar records about its node kinds: which a query can name, and
//! which supertypes cover which kinds.
//!
//! A kind is its public symbol, the id `ts_node_symbol` returns. A grammar's
//! subtype tables list raw symbols, several of which can share one public
//! symbol: rust's `_type` lists each primitive token aliased to
//! `primitive_type`.

const std = @import("std");
const ts = @import("tree-sitter");
const string_literal = @import("string_literal.zig");

/// Returns the kind spelled `spelling` in `language`, or null when it has
/// none.
pub fn resolve(language: *const ts.Language, spelling: []const u8) ?u16 {
    const id = language.idForNodeKind(spelling, true);
    return if (id == 0) null else id;
}

/// Returns the public symbol of `id`.
pub fn public(language: *const ts.Language, id: u16) u16 {
    return language.idForNodeKind(name(language, id), isNamedSymbol(language, id));
}

/// Whether `id` is named: a regular symbol or a supertype, which
/// `nodeKindIsNamed` excludes.
fn isNamedSymbol(language: *const ts.Language, id: u16) bool {
    return language.nodeKindIsNamed(id) or language.nodeKindIsSupertype(id);
}

pub fn name(language: *const ts.Language, id: u16) []const u8 {
    return language.nodeKindForId(id) orelse "";
}

/// Returns whether `id` is a kind a query can name as `:k`: a named node
/// kind, or a supertype.
pub fn isNamed(language: *const ts.Language, id: u16) bool {
    if (language.nodeKindIsSupertype(id)) return true;
    return language.nodeKindIsNamed(id) and language.nodeKindIsVisible(id);
}

/// Returns every kind a query can name, sorted by name. Caller owns the
/// slice.
pub fn named(gpa: std.mem.Allocator, language: *const ts.Language) std.mem.Allocator.Error![]u16 {
    return try collect(gpa, language, {}, struct {
        fn keep(_: void, l: *const ts.Language, id: u16) bool {
            return isNamed(l, id);
        }
    }.keep);
}

/// Returns whether `id` is `kind`, or a kind a supertype `kind` covers
/// through any chain of supertypes.
pub fn matches(language: *const ts.Language, kind: u16, id: u16) bool {
    if (id == kind) return true;
    for (language.subtypesForSupertype(kind)) |subtype| {
        if (matches(language, public(language, subtype), id)) return true;
    }
    return false;
}

/// Returns whether supertype `supertype` covers `id`, a kind other than
/// itself.
pub fn covers(language: *const ts.Language, supertype: u16, id: u16) bool {
    return supertype != id and matches(language, supertype, id);
}

/// Returns the kinds `supertype` covers that are not supertypes themselves,
/// sorted by name. Empty when `supertype` is not one. Caller owns the slice.
pub fn subtypes(gpa: std.mem.Allocator, language: *const ts.Language, supertype: u16) std.mem.Allocator.Error![]u16 {
    return try collect(gpa, language, supertype, struct {
        fn keep(s: u16, l: *const ts.Language, id: u16) bool {
            return !l.nodeKindIsSupertype(id) and covers(l, s, id);
        }
    }.keep);
}

/// Every public symbol `keep` accepts, sorted by name.
fn collect(
    gpa: std.mem.Allocator,
    language: *const ts.Language,
    context: anytype,
    comptime keep: fn (@TypeOf(context), *const ts.Language, u16) bool,
) std.mem.Allocator.Error![]u16 {
    var ids: std.ArrayList(u16) = .empty;
    errdefer ids.deinit(gpa);
    var id: u16 = 1;
    while (id < language.nodeKindCount()) : (id += 1) {
        if (public(language, id) == id and keep(context, language, id)) try ids.append(gpa, id);
    }
    std.mem.sort(u16, ids.items, language, lessByName);
    return try ids.toOwnedSlice(gpa);
}

fn lessByName(language: *const ts.Language, a: u16, b: u16) bool {
    const order = std.mem.order(u8, name(language, a), name(language, b));
    return order == .lt or (order == .eq and a < b);
}

/// Formats as `id` is written in TQL: `:k` for a named kind, `"t"` for a
/// token.
pub fn spelled(language: *const ts.Language, id: u16) Spelled {
    return .{ .named = isNamedSymbol(language, id), .name = name(language, id) };
}

pub const Spelled = struct {
    named: bool,
    name: []const u8,

    pub fn format(self: Spelled, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.named) {
            try w.print(":{s}", .{self.name});
        } else {
            try w.print("\"{f}\"", .{string_literal.fmt(self.name)});
        }
    }
};

const Registry = @import("grammar.zig").Registry;

test "a supertype matches its subtypes" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const l = (try grammars.get("python")).language;

    const expression = l.idForNodeKind("expression", true);
    const comparison = l.idForNodeKind("comparison_operator", true);
    const identifier = l.idForNodeKind("identifier", true);
    try std.testing.expect(matches(l, expression, comparison));
    try std.testing.expect(matches(l, expression, l.idForNodeKind("binary_operator", true)));
    try std.testing.expect(matches(l, identifier, identifier));
    try std.testing.expect(!matches(l, comparison, expression));
}

test "a kind several symbols alias is one subtype" {
    const gpa = std.testing.allocator;
    var grammars = Registry.init(gpa, &.{});
    defer grammars.deinit();
    const l = (try grammars.get("rust")).language;

    const types = try subtypes(gpa, l, l.idForNodeKind("_type", true));
    defer gpa.free(types);
    var primitive: usize = 0;
    for (types) |id| primitive += @intFromBool(std.mem.eql(u8, name(l, id), "primitive_type"));
    try std.testing.expectEqual(1, primitive);
}
