//! Binder names for printing. A binder prints with primes appended when its
//! scope references another symbol of the same printed name.

const std = @import("std");
const symbols = @import("symbols.zig");

const SymbolId = symbols.SymbolId;

pub const Error = std.Io.Writer.Error;

pub const Scope = struct {
    symbol: SymbolId,
    primes: u32,
    parent: ?*Scope,
};

/// Bring binders `i..` of `g` into scope, then write what they scope.
///
/// `g` supplies `len()` and `binder(i)`. `captures(printer, g, binder,
/// spelling, primes, scope)` reports whether anything `g` scopes references
/// another symbol printed as `spelling` with `primes` primes.
/// `writeScoped(printer, g, w, indent, scope)` writes the group.
pub fn enter(
    printer: anytype,
    g: anytype,
    i: usize,
    w: *std.Io.Writer,
    indent: usize,
    scope: ?*Scope,
    comptime captures: anytype,
    comptime writeScoped: anytype,
) Error!void {
    if (i < g.len()) {
        var node: Scope = .{ .symbol = g.binder(i), .primes = 0, .parent = scope };
        return enter(printer, g, i + 1, w, indent, &node, captures, writeScoped);
    }
    // The group is the innermost `g.len()` nodes, newest first.
    for (0..g.len()) |k| {
        var node = scope.?;
        for (0..g.len() - 1 - k) |_| node = node.parent.?;
        node.primes = primesFor(printer, g, node.symbol, scope, captures);
    }
    try writeScoped(printer, g, w, indent, scope);
}

fn primesFor(printer: anytype, g: anytype, binder: SymbolId, scope: ?*Scope, comptime captures: anytype) u32 {
    const spelling = printer.interner.spelling(binder);
    if (std.mem.eql(u8, spelling, "_")) return 0;
    var primes: u32 = 0;
    while (captures(printer, g, binder, spelling, primes, scope)) primes += 1;
    return primes;
}

/// The primes `id` prints with if it is in scope or a global, else null.
pub fn outerPrimes(interner: *const symbols.Interner, id: SymbolId, scope: ?*Scope) ?u32 {
    var node = scope;
    while (node) |n| : (node = n.parent) {
        if (n.symbol == id) return n.primes;
    }
    return if (interner.isGlobal(id)) 0 else null;
}

pub fn writeName(interner: *const symbols.Interner, id: SymbolId, w: *std.Io.Writer, scope: ?*Scope) Error!void {
    try interner.printed(id).format(w);
    try w.splatByteAll('\'', outerPrimes(interner, id, scope) orelse 0);
}

pub fn newline(w: *std.Io.Writer, indent: usize) Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', indent);
}
