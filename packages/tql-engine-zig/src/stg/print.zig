//! Renders STG-shaped terms, for tests and for reading what translation
//! produced.
//!
//! A closure prints as `{free} \u {args} -> body`, with `\u` for a thunk,
//! which updates, and `\n` for a function, which does not.

const std = @import("std");
const stg = @import("terms.zig");
const core = @import("../core.zig");

pub const Printer = struct {
    interner: *const core.Interner,

    /// Spelled out because `expr`, `closure` and `allocation` are mutually
    /// recursive, and an inferred set cannot close over that cycle.
    pub const Error = std.Io.Writer.Error;

    fn atom(self: Printer, a: stg.Atom, w: *std.Io.Writer) !void {
        switch (a) {
            .local => |local| try w.writeAll(self.interner.spelling(local.name)),
            .global => |id| try w.writeAll(self.interner.spelling(id)),
            .literal => |literal| switch (literal) {
                .number => |n| try w.print("{d}", .{n}),
                .string => |s| try w.print("\"{s}\"", .{s}),
                .regex => |r| try w.print("r\"{s}\"", .{r.pattern}),
            },
        }
    }

    fn atoms(self: Printer, list: []const stg.Atom, w: *std.Io.Writer) !void {
        for (list) |a| {
            try w.writeByte(' ');
            try self.atom(a, w);
        }
    }

    pub fn closure(self: Printer, c: *const stg.Closure, w: *std.Io.Writer) Error!void {
        try w.writeByte('{');
        for (c.free, 0..) |capture, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(self.interner.spelling(capture.name));
        }
        try w.writeAll("} ");
        try w.writeAll(if (c.parameters.len == 0) "\\u" else "\\n");
        try w.writeByte(' ');
        try w.writeByte('{');
        for (c.parameters, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(self.interner.spelling(p));
        }
        try w.writeAll("} -> ");
        try self.expr(c.body, w);
    }

    fn allocation(self: Printer, a: stg.Allocation, w: *std.Io.Writer) Error!void {
        switch (a) {
            .closure => |c| try self.closure(c, w),
            .constructed => |c| {
                try w.writeAll(self.interner.spelling(c.constructor));
                try self.atoms(c.fields, w);
            },
        }
    }

    pub fn expr(self: Printer, e: stg.Expr, w: *std.Io.Writer) Error!void {
        switch (e) {
            .atom => |a| try self.atom(a, w),
            .apply => |apply| {
                try self.atom(apply.callee, w);
                try self.atoms(apply.arguments, w);
            },
            .constructed => |c| {
                try w.writeAll(self.interner.spelling(c.constructor));
                try self.atoms(c.fields, w);
            },
            .primitive => |p| {
                try w.print("{s}#", .{@tagName(p.primop)});
                try self.atoms(p.arguments, w);
            },
            .case => |c| {
                try w.writeAll("case ");
                try self.expr(c.scrutinee, w);
                try w.writeAll(" of {");
                for (c.alternatives, 0..) |alternative, i| {
                    if (i > 0) try w.writeByte(';');
                    try w.print(" {s}", .{self.interner.spelling(alternative.constructor)});
                    for (alternative.binders) |binder| {
                        try w.print(" {s}", .{self.interner.spelling(binder)});
                    }
                    try w.writeAll(" -> ");
                    try self.expr(alternative.body, w);
                }
                try w.writeAll(" }");
            },
            .let => |let| {
                try w.writeAll(if (let.recursive) "letrec {" else "let {");
                for (let.bindings, 0..) |binding, i| {
                    if (i > 0) try w.writeByte(';');
                    try w.print(" {s} = ", .{self.interner.spelling(binding.binder)});
                    try self.allocation(binding.value, w);
                }
                try w.writeAll(" } in ");
                try self.expr(let.body, w);
            },
        }
    }
};
