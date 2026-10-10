//! Serves module `A.B` from `A/B.tql` under the first root holding it.

const std = @import("std");
const tql = @import("tql");

const FileLoader = @This();

io: std.Io,
gpa: std.mem.Allocator,
roots: []const []const u8,
/// Each file read, freed with the loader.
read: std.ArrayList(tql.diagnostic.Source) = .empty,
/// Why the latest load failed, if it did.
failure: std.ArrayList(u8) = .empty,

pub fn deinit(self: *FileLoader) void {
    for (self.read.items) |source| {
        self.gpa.free(source.name.?);
        self.gpa.free(source.text);
    }
    self.read.deinit(self.gpa);
    self.failure.deinit(self.gpa);
}

pub fn loader(self: *FileLoader) tql.Loader {
    return .{ .context = self, .loadFn = load };
}

fn load(context: *anyopaque, name: []const u8) tql.load.Loaded {
    const self: *FileLoader = @ptrCast(@alignCast(context));
    return self.find(name) catch |err| .{ .failed = @errorName(err) };
}

fn find(self: *FileLoader, name: []const u8) !tql.load.Loaded {
    const relative = try std.mem.concat(self.gpa, u8, &.{ name, ".tql" });
    defer self.gpa.free(relative);
    std.mem.replaceScalar(u8, relative[0..name.len], '.', std.fs.path.sep);

    for (self.roots) |root| {
        const path = try std.fs.path.join(self.gpa, &.{ root, relative });
        const text = readQueryFile(self.io, self.gpa, path) catch |err| {
            defer self.gpa.free(path);
            switch (err) {
                // The root does not hold the module, or is not a directory.
                error.FileNotFound, error.NotDir => continue,
                else => {
                    self.failure.clearRetainingCapacity();
                    try self.failure.print(self.gpa, "`{s}`: {t}", .{ path, err });
                    return .{ .failed = self.failure.items };
                },
            }
        };
        const source: tql.diagnostic.Source = .{ .name = path, .text = text };
        self.read.append(self.gpa, source) catch |err| {
            self.gpa.free(path);
            self.gpa.free(text);
            return err;
        };
        return .{ .found = source };
    }
    return .missing;
}

pub fn readQueryFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
}

/// Where imports are searched, in order: the query file's directory, each
/// `-I` directory, then each directory in `TQL_PATH`. An inline query has no
/// directory of its own. The slices borrow from the arguments and `env`.
pub fn moduleRoots(
    gpa: std.mem.Allocator,
    query_path: ?[]const u8,
    includes: []const []const u8,
    env: *const std.process.Environ.Map,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer roots.deinit(gpa);
    if (query_path) |p| try roots.append(gpa, std.fs.path.dirname(p) orelse ".");
    try roots.appendSlice(gpa, includes);
    if (env.get("TQL_PATH")) |path| {
        var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
        while (it.next()) |part| {
            if (part.len > 0) try roots.append(gpa, part);
        }
    }
    return try roots.toOwnedSlice(gpa);
}

test "imports search the query's directory, then -I, then TQL_PATH" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("TQL_PATH", "/env/a::/env/b");

    const roots = try moduleRoots(gpa, "rules/q.tql", &.{ "lib", "vendor" }, &env);
    defer gpa.free(roots);
    try std.testing.expectEqual(5, roots.len);
    for ([_][]const u8{ "rules", "lib", "vendor", "/env/a", "/env/b" }, roots) |expected, root| {
        try std.testing.expectEqualStrings(expected, root);
    }
}

test "an inline query searches only -I and TQL_PATH" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const roots = try moduleRoots(gpa, null, &.{"lib"}, &env);
    defer gpa.free(roots);
    try std.testing.expectEqual(1, roots.len);
    try std.testing.expectEqualStrings("lib", roots[0]);
}
