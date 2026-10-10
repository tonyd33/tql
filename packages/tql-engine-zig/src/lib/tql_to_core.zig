//! Module for converting surface TQL syntax to Core, a lower-level
//! lambda-style language.

const annotation = @import("tql_to_core/annotation.zig");
const desugar = @import("tql_to_core/desugar.zig");
const link_mod = @import("tql_to_core/link.zig");

/// Desugars source files into one linked `core.Program`.
pub const Desugarer = link_mod.Desugarer;
pub const Import = scope_mod.Import;
pub const Filter = scope_mod.Filter;
pub const Exports = scope_mod.Exports;

test {
    std.testing.refAllDecls(link_mod);
    std.testing.refAllDecls(desugar);
    std.testing.refAllDecls(@import("tql_to_core/resolve.zig"));
    std.testing.refAllDecls(@import("tql_to_core/scope.zig"));
    std.testing.refAllDecls(annotation);
    std.testing.refAllDecls(@import("tql_to_core/classes.zig"));
}

const std = @import("std");
const core = @import("core.zig");
const cst = @import("lang/cst.zig");
const diagnostic = @import("diagnostic.zig");
const test_support = core.test_support;
const scope_mod = @import("tql_to_core/scope.zig");
const ModuleScope = scope_mod.ModuleScope;

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Translates hand-built `cst.Type` signatures against an environment holding
/// the structural types.
const Fixture = struct {
    env: core.env.Env,
    sink: diagnostic.Sink,

    fn init(gpa: Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .env = try test_support.env(gpa),
            .sink = diagnostic.Sink.init(gpa),
        };
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.sink.deinit();
        self.env.deinit();
        gpa.destroy(self);
    }

    /// `Prim`'s own view: every structural type, no imports.
    fn scope(self: *const Fixture) ModuleScope {
        return .{
            .module = .prim,
            .imports = &.{},
            .exports = &.{},
            .interner = &self.env.interner,
            .datatypes = &self.env.datatypes,
            .classes = &self.env.classes,
        };
    }

    fn node(self: *Fixture, kind: cst.Type.Kind) cst.Type {
        _ = self;
        return .{ .kind = kind, .span = diagnostic.Span.unknown };
    }
};

/// `v0 -> v1 -> ... -> Int` over `count` distinct variables.
fn manyVariables(fix: *Fixture, count: usize) !cst.Type {
    const arena = fix.env.allocator();
    var t = fix.node(.{ .constructor = "Int" });
    var i = count;
    while (i > 0) {
        i -= 1;
        const arrow = try arena.create(cst.FunctionType);
        arrow.* = .{
            .from = fix.node(.{ .variable = try std.fmt.allocPrint(arena, "v{d}", .{i}) }),
            .to = t,
        };
        t = fix.node(.{ .function = arrow });
    }
    return t;
}

test "a signature may have as many variables as a scheme can number" {
    const gpa = testing.allocator;
    const fix = try Fixture.init(gpa);
    defer fix.deinit(gpa);

    const signature: cst.Signature = .{ .name = "f", .type = try manyVariables(fix, 255) };
    const scheme = try annotation.translate(fix.env.allocator(), gpa, &signature, &fix.scope(), &fix.sink);
    try testing.expectEqual(255, scheme.variables.len);
}
