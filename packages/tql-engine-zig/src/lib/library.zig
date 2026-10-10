//! The modules shipped inside the engine, compiled once into a link that
//! every query's link extends.

const std = @import("std");
const core = @import("core.zig");
const diagnostic = @import("diagnostic.zig");
const parse = @import("parse.zig");
const tql_to_core = @import("tql_to_core.zig");
const load = @import("load.zig");

pub const prelude_name = "Prelude";

/// Every library module, `Prim` first. Each imports only modules before it.
/// A link declares them first, in this order, so the module at index `i` is
/// `ModuleId` `i`.
pub const modules = [_]load.Named{
    .{ .name = core.ModuleId.prim_name, .path = "Prim.tql", .text = @embedFile("library/Prim.tql") },
    .{ .name = "Data.Bool", .path = "Data/Bool.tql", .text = @embedFile("library/Data/Bool.tql") },
    .{ .name = "Data.Ord", .path = "Data/Ord.tql", .text = @embedFile("library/Data/Ord.tql") },
    .{ .name = "Control.Category", .path = "Control/Category.tql", .text = @embedFile("library/Control/Category.tql") },
    .{ .name = "Data.Function", .path = "Data/Function.tql", .text = @embedFile("library/Data/Function.tql") },
    .{ .name = "Data.Tuple", .path = "Data/Tuple.tql", .text = @embedFile("library/Data/Tuple.tql") },
    .{ .name = "Data.Monoid", .path = "Data/Monoid.tql", .text = @embedFile("library/Data/Monoid.tql") },
    .{ .name = "Data.Functor", .path = "Data/Functor.tql", .text = @embedFile("library/Data/Functor.tql") },
    .{ .name = "Control.Applicative", .path = "Control/Applicative.tql", .text = @embedFile("library/Control/Applicative.tql") },
    .{ .name = "Data.Foldable", .path = "Data/Foldable.tql", .text = @embedFile("library/Data/Foldable.tql") },
    .{ .name = "Data.Traversable", .path = "Data/Traversable.tql", .text = @embedFile("library/Data/Traversable.tql") },
    .{ .name = "Control.Monad", .path = "Control/Monad.tql", .text = @embedFile("library/Control/Monad.tql") },
    .{ .name = "Control.Arrow", .path = "Control/Arrow.tql", .text = @embedFile("library/Control/Arrow.tql") },
    .{ .name = "Data.Maybe", .path = "Data/Maybe.tql", .text = @embedFile("library/Data/Maybe.tql") },
    .{ .name = "Data.List", .path = "Data/List.tql", .text = @embedFile("library/Data/List.tql") },
    .{ .name = "Data.Filter", .path = "Data/Filter.tql", .text = @embedFile("library/Data/Filter.tql") },
    .{ .name = "Data.Node", .path = "Data/Node.tql", .text = @embedFile("library/Data/Node.tql") },
    .{ .name = "Data.Int", .path = "Data/Int.tql", .text = @embedFile("library/Data/Int.tql") },
    .{ .name = prelude_name, .path = "Prelude.tql", .text = @embedFile("library/Prelude.tql") },
};

/// The module that exports each `core.Known` under its spelling.
const known_owners: std.EnumArray(core.Known, []const u8) = .init(.{
    .eq = core.ModuleId.prim_name,
    .compare = core.ModuleId.prim_name,
    .@"and" = "Data.Bool",
    .@"or" = "Data.Bool",
    .bind = "Control.Monad",
    .empty = "Control.Applicative",
    .compose = "Control.Category",
    .compose_flipped = "Control.Category",
    .kleisli = "Control.Monad",
    .alt = "Control.Applicative",
    .run = "Data.Filter",
    .Filter = "Data.Filter",
    .of_kind = "Data.Node",
});

/// Returns the library module named `name`.
pub fn named(name: []const u8) ?core.ModuleId {
    for (modules, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return @enumFromInt(i);
    }
    return null;
}

/// The module every other imports implicitly.
pub const prelude = named(prelude_name).?;

/// The source id a library module's spans carry: the first ids after the
/// entry's, in `modules` order.
fn sourceOf(index: usize) diagnostic.SourceId {
    return @enumFromInt(index + 1);
}

/// Adds every library module's source to `sources`, so each takes the id
/// `sourceOf` names.
///
/// Preconditions:
/// - `sources` is empty.
pub fn addSources(sources: *diagnostic.Sources) !void {
    for (modules, 0..) |m, i| {
        const id = try sources.add(.{ .name = m.path, .text = m.text });
        std.debug.assert(id == sourceOf(i));
    }
}

/// The library desugared and linked. Nothing changes it once built, so links
/// on several threads may extend one.
pub const Library = struct {
    desugarer: tql_to_core.Desugarer,

    /// Compiles every library module. A failure is a bug in this repository;
    /// its diagnostics go to `sink`, with spans `addSources` can resolve.
    pub fn init(gpa: std.mem.Allocator, sink: *diagnostic.Sink) !Library {
        var parser = try parse.Parser.init(gpa);
        defer parser.deinit();
        var desugarer = try tql_to_core.Desugarer.init(gpa);
        errdefer desugarer.deinit();

        for (modules[1..], 1..) |m, i| {
            const id = try desugarer.declareModule(m.name);
            std.debug.assert(@intFromEnum(id) == i);
        }

        const env = &desugarer.env.?;
        var imports: std.ArrayList(tql_to_core.Import) = .empty;
        defer imports.deinit(gpa);
        for (modules, 0..) |m, i| {
            const id: core.ModuleId = @enumFromInt(i);
            var parsed = try parser.parseCollecting(m.text, sourceOf(i));
            defer parsed.deinit();
            if (parsed.hasErrors()) {
                try sink.extend(parsed.diagnostics);
                return error.PreludeInvalid;
            }

            imports.clearRetainingCapacity();
            for (parsed.source_file.imports) |import| {
                const imported = named(import.module) orelse return error.PreludeInvalid;
                try imports.append(gpa, .{ .module = imported, .qualifier = import.qualifier, .selects = import.selects });
            }
            desugarer.add(id, imports.items, parsed.source_file, null, sink) catch |err| switch (err) {
                error.DesugarFailed => return error.PreludeInvalid,
                else => |e| return e,
            };
            for (std.enums.values(core.Known)) |k| {
                if (!std.mem.eql(u8, known_owners.get(k), m.name)) continue;
                env.known.set(k, desugarer.exports.items[i].values.get(@tagName(k)) orelse return error.PreludeInvalid);
            }
        }
        for (env.known.values) |symbol| if (symbol == null) return error.PreludeInvalid;
        return .{ .desugarer = desugarer };
    }

    pub fn deinit(self: *Library) void {
        self.desugarer.deinit();
    }

    /// A desugarer holding the library, for one link. `self` must outlive it
    /// and every program it finishes.
    pub fn link(self: *const Library, gpa: std.mem.Allocator) !tql_to_core.Desugarer {
        return try tql_to_core.Desugarer.extend(gpa, &self.desugarer);
    }
};
