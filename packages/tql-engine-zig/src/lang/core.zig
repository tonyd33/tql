//! Core terms.
//!
//! ```
//! expr ::= symbol
//!        | literal
//!        | \x -> expr
//!        | expr_1 expr_2
//!        | if expr_1 then expr_2 else expr_3
//!        | letrec { x_1 = expr_1; ...; x_i = expr_i; } in expr_N
//!        | bind x <- expr_1 in expr_2
//! ```

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const symbols = @import("symbols.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
//                              Terms
// ============================================================================

pub const Term = struct {
    kind: Kind,
    /// Where this term came from, before desugaring.
    span: diagnostic.Span,

    pub const Kind = union(enum) {
        symbol: symbols.SymbolId,
        literal: Literal,
        lambda: *const Lambda,
        apply: *const Apply,
        conditional: *const Conditional,
        letrec: *const Letrec,
        bind: *const Bind,
    };
};

pub const Literal = union(enum) {
    boolean: bool,
    number: i64,
    string: []const u8,
    regex: []const u8,
};

pub const Lambda = struct {
    parameter: symbols.SymbolId,
    body: Term,
};

pub const Apply = struct {
    function: Term,
    argument: Term,
};

pub const Conditional = struct {
    condition: Term,
    consequence: Term,
    alternative: Term,
};

pub const Letrec = struct {
    bindings: []const Binding,
    body: Term,

    pub const Binding = struct {
        name: symbols.SymbolId,
        value: Term,
    };
};

pub const Bind = struct {
    name: symbols.SymbolId,
    value: Term,
    body: Term,
};

/// A top-level definition.
pub const Definition = struct {
    symbol: symbols.SymbolId,
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

    pub fn symbol(self: Builder, id: symbols.SymbolId, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .symbol = id }, .span = span };
    }

    pub fn literal(self: Builder, value: Literal, span: diagnostic.Span) Term {
        _ = self;
        return .{ .kind = .{ .literal = value }, .span = span };
    }
    pub fn lambda(self: Builder, parameter: symbols.SymbolId, body: Term, span: diagnostic.Span) !Term {
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

    pub fn conditional(
        self: Builder,
        condition: Term,
        consequence: Term,
        alternative: Term,
        span: diagnostic.Span,
    ) !Term {
        const node = try self.allocator.create(Conditional);
        node.* = .{
            .condition = condition,
            .consequence = consequence,
            .alternative = alternative,
        };
        return .{ .kind = .{ .conditional = node }, .span = span };
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

    pub fn bind(self: Builder, name: symbols.SymbolId, value: Term, body: Term, span: diagnostic.Span) !Term {
        const node = try self.allocator.create(Bind);
        node.* = .{ .name = name, .value = value, .body = body };
        return .{ .kind = .{ .bind = node }, .span = span };
    }
};

/// Emits one line per term. Terms are compared structurally, so line breaks
/// carry no meaning.
pub const Printer = struct {
    interner: *const symbols.Interner,

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
            .conditional => |c| {
                const wrap = position != .top;
                if (wrap) try w.writeByte('(');
                try w.writeAll("if ");
                try self.write(c.condition, w, .top);
                try w.writeAll(" then ");
                try self.write(c.consequence, w, .top);
                try w.writeAll(" else ");
                try self.write(c.alternative, w, .top);
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
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .regex => |r| try w.print("r\"{s}\"", .{r}),
        }
    }
};
