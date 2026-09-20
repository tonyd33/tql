//! Core terms.
//!
//! ```
//! expr ::= symbol
//!        | literal
//!        | \x -> expr
//!        | expr_1 expr_2
//!        | case expr of { C x_1 .. x_n -> expr; ... }
//!        | letrec { x_1 = expr_1; ...; x_i = expr_i; } in expr_N
//!        | bind x <- expr_1 in expr_2
//! ```

const std = @import("std");
const pcre2 = @import("regex.zig");
const diagnostic = @import("diagnostic.zig");

pub const symbols = @import("core/symbols.zig");
pub const details = @import("core/details.zig");
pub const types = @import("core/types.zig");
pub const datatypes = @import("core/datatypes.zig");

pub const Details = details.Details;
pub const Synthesized = details.Synthesized;
pub const PrimOp = details.PrimOp;
pub const Scalar = details.Scalar;
pub const Symbol = symbols.Symbol;
pub const TypeId = symbols.TypeId;

pub const SymbolId = symbols.SymbolId;
pub const SymbolTable = symbols.SymbolTable;
pub const Interner = symbols.Interner;
pub const InsertError = symbols.InsertError;

const Allocator = std.mem.Allocator;

// ============================================================================
//                              Terms
// ============================================================================

pub const Term = struct {
    kind: Kind,
    /// Where this term came from, before desugaring.
    // IMPROVE: parameterize this
    span: diagnostic.Span,

    pub const Kind = union(enum) {
        symbol: SymbolId,
        literal: Literal,
        lambda: *const Lambda,
        apply: *const Apply,
        case: *const Case,
        letrec: *const Letrec,
        bind: *const Bind,
    };
};

pub const Literal = union(enum) {
    number: i64,
    string: []const u8,
    regex: Regex,
};

/// A regex literal: the pattern as written, and the program compiled from it.
///
/// Compiled once, when the literal is desugared. The pattern is kept because
/// printing a term must show what the source said.
pub const Regex = struct {
    pattern: []const u8,
    compiled: pcre2.Regex,
};

pub const Lambda = struct {
    parameter: SymbolId,
    body: Term,
};

pub const Apply = struct {
    function: Term,
    argument: Term,
};

pub const Case = struct {
    scrutinee: Term,
    alternatives: []const Alternative,

    pub const Alternative = struct {
        constructor: SymbolId,
        binders: []const SymbolId,
        body: Term,
    };
};

pub const Letrec = struct {
    bindings: []const Binding,
    body: Term,

    pub const Binding = struct {
        name: SymbolId,
        value: Term,
    };
};

pub const Bind = struct {
    name: SymbolId,
    value: Term,
    body: Term,
};

/// A top-level definition.
pub const Definition = struct {
    symbol: SymbolId,
    body: Term,
    span: diagnostic.Span,
};

/// Builds the compound terms into an arena. Every term outlives the builder.
pub const Builder = struct {
    allocator: Allocator,

    pub fn dupe(self: Builder, text: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, text);
    }

    pub fn slice(self: Builder, comptime T: type, n: usize) ![]T {
        return try self.allocator.alloc(T, n);
    }

    pub fn dupeSlice(self: Builder, comptime T: type, values: []const T) ![]T {
        return try self.allocator.dupe(T, values);
    }

    pub fn join(self: Builder, separator: []const u8, parts: []const []const u8) ![]const u8 {
        return try std.mem.join(self.allocator, separator, parts);
    }

    pub fn print(self: Builder, comptime format: []const u8, args: anytype) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, format, args);
    }

    pub fn symbol(self: Builder, id: SymbolId, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .symbol = id }, .span = span };
    }

    pub fn literal(self: Builder, value: Literal, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .literal = value }, .span = span };
    }
    pub fn lambda(self: Builder, parameter: SymbolId, body: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Lambda);
        node.* = .{ .parameter = parameter, .body = body };
        return .{ .kind = .{ .lambda = node }, .span = span };
    }

    pub fn apply(self: Builder, function: Term, argument: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Apply);
        node.* = .{ .function = function, .argument = argument };
        return .{ .kind = .{ .apply = node }, .span = span };
    }

    /// `f a b` as `(f a) b`, sharing one span.
    pub fn applyMany(self: Builder, function: Term, arguments: []const Term, span: diagnostic.Span) !Term {
        var result = function;
        for (arguments) |argument| result = try self.apply(result, argument, span);
        return result;
    }

    pub fn case(
        self: Builder,
        scrutinee: Term,
        alternatives: []const Case.Alternative,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Case);
        node.* = .{ .scrutinee = scrutinee, .alternatives = alternatives };
        return .{ .kind = .{ .case = node }, .span = span };
    }

    pub fn letrec(
        self: Builder,
        bindings: []const Letrec.Binding,
        body: Term,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Letrec);
        node.* = .{ .bindings = bindings, .body = body };
        return .{ .kind = .{ .letrec = node }, .span = span };
    }

    pub fn bind(self: Builder, name: SymbolId, value: Term, body: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Bind);
        node.* = .{ .name = name, .value = value, .body = body };
        return .{ .kind = .{ .bind = node }, .span = span };
    }
};

/// Emits one line per term. Terms are compared structurally, so line breaks
/// carry no meaning.
pub const Printer = struct {
    interner: *const Interner,

    pub fn term(self: Printer, t: Term, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.write(t, w, .top);
    }

    /// Where a term sits, which decides whether it needs parentheses.
    const Position = enum {
        /// Nothing binds tighter; never parenthesized.
        top,
        /// Left of an application: only an application may sit here bare.
        callee,
        /// Right of an application, or an `if` operand.
        operand,
    };

    fn write(
        self: Printer,
        t: Term,
        w: *std.Io.Writer,
        position: Position,
    ) std.Io.Writer.Error!void {
        switch (t.kind) {
            .symbol => |id| try w.writeAll(self.interner.spelling(id)),
            .literal => |value| try writeLiteral(value, w),
            .lambda => |l| {
                const wrap = position != .top;
                if (wrap) try w.writeByte('(');
                try w.print("\\{s} -> ", .{self.interner.spelling(l.parameter)});
                try self.write(l.body, w, .top);
                if (wrap) try w.writeByte(')');
            },
            .apply => |a| {
                const wrap = position == .operand;
                if (wrap) try w.writeByte('(');
                try self.write(a.function, w, .callee);
                try w.writeByte(' ');
                try self.write(a.argument, w, .operand);
                if (wrap) try w.writeByte(')');
            },
            .case => |c| {
                const wrap = position != .top;
                if (wrap) try w.writeByte('(');
                try w.writeAll("case ");
                try self.write(c.scrutinee, w, .top);
                try w.writeAll(" of { ");
                for (c.alternatives, 0..) |alternative, i| {
                    if (i > 0) try w.writeAll("; ");
                    try w.writeAll(self.interner.spelling(alternative.constructor));
                    for (alternative.binders) |binder| {
                        try w.print(" {s}", .{self.interner.spelling(binder)});
                    }
                    try w.writeAll(" -> ");
                    try self.write(alternative.body, w, .top);
                }
                try w.writeAll(" }");
                if (wrap) try w.writeByte(')');
            },
            .letrec => |l| {
                const wrap = position != .top;
                if (wrap) try w.writeByte('(');
                try w.writeAll("letrec { ");
                for (l.bindings, 0..) |b, i| {
                    if (i > 0) try w.writeAll("; ");
                    try w.print("{s} = ", .{self.interner.spelling(b.name)});
                    try self.write(b.value, w, .top);
                }
                try w.writeAll(" } in ");
                try self.write(l.body, w, .top);
                if (wrap) try w.writeByte(')');
            },
            .bind => |b| {
                const wrap = position != .top;
                if (wrap) try w.writeByte('(');
                try w.print("bind {s} <- ", .{self.interner.spelling(b.name)});
                try self.write(b.value, w, .top);
                try w.writeAll(" in ");
                try self.write(b.body, w, .top);
                if (wrap) try w.writeByte(')');
            },
        }
    }

    fn writeLiteral(value: Literal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value) {
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .regex => |r| try w.print("r\"{s}\"", .{r.pattern}),
        }
    }
};
