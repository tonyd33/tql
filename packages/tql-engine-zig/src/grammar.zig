const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree-sitter");
const build_options = @import("build_options");

const can_dlopen = switch (builtin.os.tag) {
    .wasi, .freestanding => false,
    else => true,
};

const ENV_GRAMMAR_PATH = "TQL_GRAMMAR_PATH";

pub const Grammar = struct {
    name: []const u8,
    extensions: []const []const u8,
    language: *const ts.Language,

    pub const static_grammars: []const StaticEntry = blk: {
        const selected = build_options.static_grammars;
        var entries: [selected.len]StaticEntry = undefined;
        var n: usize = 0;
        for (selected) |name| {
            if (lookupEntry(name)) |entry| {
                entries[n] = entry;
                n += 1;
            }
        }
        const result = entries[0..n].*;
        break :blk &result;
    };
    /// Resolves grammar search paths from the environment per XDG spec.
    /// Caller owns the returned slice and every path string within (all
    /// duplicated into `allocator`).
    pub fn resolveSearchPaths(
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
    ) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;

        if (env.get(ENV_GRAMMAR_PATH)) |p| {
            var it = std.mem.splitScalar(u8, p, ':');
            while (it.next()) |part| {
                if (part.len > 0) try list.append(allocator, try allocator.dupe(u8, part));
            }
        }

        if (env.get("XDG_DATA_HOME")) |xdg| {
            try list.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "tql", "grammars" }));
        } else if (env.get("HOME")) |home| {
            try list.append(allocator, try std.fs.path.join(allocator, &.{ home, ".local", "share", "tql", "grammars" }));
        }

        const xdg_dirs = env.get("XDG_DATA_DIRS") orelse "/usr/local/share/:/usr/share/";
        var it = std.mem.splitScalar(u8, xdg_dirs, ':');
        while (it.next()) |part| {
            if (part.len > 0) try list.append(allocator, try std.fs.path.join(allocator, &.{ part, "tql", "grammars" }));
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn matchesFileName(self: *const Grammar, file_name: []const u8) bool {
        for (self.extensions) |ext| {
            if (std.mem.endsWith(u8, file_name, ext)) return true;
        }
        return false;
    }
};

const GrammarFn = *const fn () callconv(.c) *const ts.Language;

const DynLibHandle = if (can_dlopen) std.DynLib else void;

const StaticEntry = struct {
    name: []const u8,
    extensions: []const []const u8,
    get: GrammarFn,
};

fn lookupEntry(comptime name: []const u8) ?StaticEntry {
    for (grammar_meta) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            const sym = comptime std.fmt.comptimePrint("tree_sitter_{s}", .{name});
            const f: GrammarFn = @extern(GrammarFn, .{ .name = sym });
            return StaticEntry{ .name = e.name, .extensions = e.extensions, .get = f };
        }
    }
    return null;
}

const grammar_meta = [_]struct {
    name: []const u8,
    extensions: []const []const u8,
}{
    .{ .name = "cpp", .extensions = &.{ ".cpp", ".cc", ".hpp" } },
    .{ .name = "c", .extensions = &.{ ".c", ".h" } },
    .{ .name = "c_sharp", .extensions = &.{".cs"} },
    .{ .name = "go", .extensions = &.{".go"} },
    .{ .name = "javascript", .extensions = &.{".js"} },
    .{ .name = "python", .extensions = &.{".py"} },
    .{ .name = "rust", .extensions = &.{".rs"} },
    .{ .name = "tsx", .extensions = &.{".tsx"} },
    .{ .name = "typescript", .extensions = &.{".ts"} },
    .{ .name = "zig", .extensions = &.{".zig"} },
    .{ .name = "lua", .extensions = &.{".lua"} },
    .{ .name = "ruby", .extensions = &.{".rb"} },
    .{ .name = "bash", .extensions = &.{ ".sh", ".bash" } },
    .{ .name = "json", .extensions = &.{".json"} },
    .{ .name = "html", .extensions = &.{ ".html", ".htm" } },
    .{ .name = "css", .extensions = &.{".css"} },
    .{ .name = "cmake", .extensions = &.{".cmake"} },
    .{ .name = "dockerfile", .extensions = &.{"Dockerfile"} },
    .{ .name = "elixir", .extensions = &.{ ".ex", ".exs" } },
    .{ .name = "erlang", .extensions = &.{ ".erl", ".hrl" } },
    .{ .name = "graphql", .extensions = &.{ ".graphql", ".gql" } },
    .{ .name = "haskell", .extensions = &.{".hs"} },
    .{ .name = "hcl", .extensions = &.{ ".hcl", ".tf" } },
    .{ .name = "java", .extensions = &.{".java"} },
    .{ .name = "kotlin", .extensions = &.{ ".kt", ".kts" } },
    .{ .name = "make", .extensions = &.{ ".mk", "Makefile" } },
    .{ .name = "markdown", .extensions = &.{ ".md", ".markdown" } },
    .{ .name = "nix", .extensions = &.{".nix"} },
    .{ .name = "ocaml", .extensions = &.{".ml"} },
    .{ .name = "php", .extensions = &.{".php"} },
    .{ .name = "scala", .extensions = &.{ ".scala", ".sc" } },
    .{ .name = "solidity", .extensions = &.{".sol"} },
    .{ .name = "toml", .extensions = &.{".toml"} },
    .{ .name = "vue", .extensions = &.{".vue"} },
    .{ .name = "yaml", .extensions = &.{ ".yaml", ".yml" } },
    .{ .name = "tql", .extensions = &.{".tql"} },
};

const LoadedGrammar = struct {
    grammar: Grammar,
    lib: ?DynLibHandle,
    dynamic: bool,
};

pub const DynInfo = struct {
    name: []const u8,
    dir: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    search_paths: []const []const u8 = &.{},
    entries: std.StringHashMapUnmanaged(*LoadedGrammar) = .empty,

    pub fn init(allocator: std.mem.Allocator, search_paths: []const []const u8) Registry {
        return .{ .allocator = allocator, .search_paths = search_paths };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const loaded = entry_ptr.*;
            if (can_dlopen) {
                if (loaded.lib) |*lib| lib.close();
            }
            if (loaded.dynamic) {
                self.allocator.free(loaded.grammar.name);
                for (loaded.grammar.extensions) |ext| self.allocator.free(ext);
                self.allocator.free(loaded.grammar.extensions);
            }
            self.allocator.destroy(loaded);
        }
        self.entries.deinit(self.allocator);
    }

    /// Look up grammar by name. Tries bundled first, then dlopen search paths.
    pub fn get(self: *Registry, name: []const u8) !*const Grammar {
        if (self.entries.get(name)) |loaded| return &loaded.grammar;

        for (Grammar.static_grammars) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                return try self.intern(b.name, b.extensions, b.get(), null, false);
            }
        }

        if (!can_dlopen) return error.GrammarNotFound;
        return try self.loadDynamic(name);
    }

    fn intern(
        self: *Registry,
        name: []const u8,
        extensions: []const []const u8,
        language: *const ts.Language,
        lib: ?DynLibHandle,
        own: bool,
    ) !*const Grammar {
        const owned_name: []const u8 = if (own) try self.allocator.dupe(u8, name) else name;
        errdefer if (own) self.allocator.free(owned_name);

        const owned_exts: []const []const u8 = if (own) blk: {
            const exts = try self.allocator.alloc([]const u8, extensions.len);
            errdefer self.allocator.free(exts);
            var dup_count: usize = 0;
            errdefer for (exts[0..dup_count]) |e| self.allocator.free(e);
            for (extensions, 0..) |ext, i| {
                exts[i] = try self.allocator.dupe(u8, ext);
                dup_count += 1;
            }
            break :blk exts;
        } else extensions;
        errdefer if (own) self.allocator.free(owned_exts);

        const loaded = try self.allocator.create(LoadedGrammar);
        errdefer self.allocator.destroy(loaded);
        loaded.* = .{
            .grammar = .{
                .name = owned_name,
                .extensions = owned_exts,
                .language = language,
            },
            .lib = lib,
            .dynamic = own,
        };

        try self.entries.put(self.allocator, loaded.grammar.name, loaded);
        return &loaded.grammar;
    }

    fn loadDynamic(self: *Registry, name: []const u8) !*const Grammar {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const file = try std.fmt.allocPrint(a, "libtree-sitter-{s}.so", .{name});
        const sym = try std.fmt.allocPrintSentinel(a, "tree_sitter_{s}", .{name}, 0);

        for (self.search_paths) |dir| {
            const full = try std.fs.path.join(a, &.{ dir, file });
            var lib = std.DynLib.open(full) catch continue;
            const grammar_fn = lib.lookup(GrammarFn, sym) orelse {
                lib.close();
                continue;
            };
            const language = grammar_fn();
            const fallback: [1][]const u8 = .{try std.fmt.allocPrint(a, ".{s}", .{name})};
            const exts = defaultExtensions(name) orelse &fallback;
            return try self.intern(name, exts, language, lib, true);
        }
        return error.GrammarNotFound;
    }

    /// Scans search paths for `libtree-sitter-<name>.so` files. Returns one
    /// entry per (name, dir) pair.
    ///
    /// Caller owns the returned slice and the name/dir slices within
    /// (allocated from `allocator`). On platforms without dlopen returns an
    /// empty slice.
    pub fn listDynamic(self: *Registry, io: std.Io) ![]const DynInfo {
        if (!can_dlopen) return &.{};

        var result: std.ArrayList(DynInfo) = .empty;
        for (self.search_paths) |dir_path| {
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                const name = entry.name;
                const prefix = "libtree-sitter-";
                const suffix = ".so";
                if (!std.mem.startsWith(u8, name, prefix)) continue;
                if (!std.mem.endsWith(u8, name, suffix)) continue;
                const inner = name[prefix.len .. name.len - suffix.len];
                if (inner.len == 0) continue;

                try result.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, inner),
                    .dir = try self.allocator.dupe(u8, dir_path),
                });
            }
        }
        return result.toOwnedSlice(self.allocator);
    }
};

fn defaultExtensions(name: []const u8) ?[]const []const u8 {
    for (grammar_meta) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.extensions;
    }
    return null;
}
