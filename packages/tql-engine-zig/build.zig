const std = @import("std");

// Must match .version in build.zig.zon.
const VERSION = "0.2.0";

const TreeSitterGrammar = struct {
    dep_name: []const u8,
    root: []const u8 = ".",
    has_scanner: bool = false,
    flags: []const []const u8 = &.{
        "-std=c11",
        "-fPIC",
    },
    /// Name used for the .so artifact and grammar lookup (defaults to dep_name
    /// stripped of "tree-sitter-" prefix). Required when one dep produces
    /// multiple grammars (e.g. typescript + tsx).
    out_name: ?[]const u8 = null,

    fn outName(self: TreeSitterGrammar) []const u8 {
        if (self.out_name) |n| return n;
        const prefix = "tree-sitter-";
        if (std.mem.startsWith(u8, self.dep_name, prefix)) {
            return self.dep_name[prefix.len..];
        }
        return self.dep_name;
    }
};

const grammars: []const TreeSitterGrammar = &.{
    .{
        .dep_name = "tree-sitter-cpp",
        .has_scanner = true,
    },
    .{
        .dep_name = "tree-sitter-c",
    },
    .{
        .dep_name = "tree-sitter-go",
    },
    .{
        .dep_name = "tree-sitter-javascript",
        .has_scanner = true,
    },
    .{
        .dep_name = "tree-sitter-python",
        .has_scanner = true,
    },
    .{
        .dep_name = "tree-sitter-rust",
        .has_scanner = true,
    },
    .{
        .dep_name = "tree-sitter-typescript",
        .root = "typescript",
        .has_scanner = true,
        .out_name = "typescript",
    },
    .{
        .dep_name = "tree-sitter-typescript",
        .root = "tsx",
        .has_scanner = true,
        .out_name = "tsx",
    },
    .{
        .dep_name = "tree-sitter-zig",
    },
};

fn addGrammar(
    b: *std.Build,
    mod: *std.Build.Module,
    grammar: TreeSitterGrammar,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const include = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ grammar.root, "src" });

    const tree_sitter_grammar = b.dependency(grammar.dep_name, .{
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(tree_sitter_grammar.path(include));
    mod.addCSourceFiles(.{
        .root = tree_sitter_grammar.path(grammar.root),
        .files = if (grammar.has_scanner) &.{ "src/parser.c", "src/scanner.c" } else &.{"src/parser.c"},
        .flags = grammar.flags,
    });
}

fn buildGrammarSharedLib(
    b: *std.Build,
    grammar: TreeSitterGrammar,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const include = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ grammar.root, "src" });

    const dep = b.dependency(grammar.dep_name, .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(dep.path(include));
    mod.addCSourceFiles(.{
        .root = dep.path(grammar.root),
        .files = if (grammar.has_scanner) &.{ "src/parser.c", "src/scanner.c" } else &.{"src/parser.c"},
        .flags = grammar.flags,
    });

    const name = try std.fmt.allocPrint(b.allocator, "tree-sitter-{s}", .{grammar.outName()});
    return b.addLibrary(.{
        .name = name,
        .root_module = mod,
        .linkage = .dynamic,
    });
}

fn addEngineDeps(
    b: *std.Build,
    mod: *std.Build.Module,
    selected: []const TreeSitterGrammar,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("tree-sitter", tree_sitter.module("tree_sitter"));

    for (selected) |grammar| {
        try addGrammar(b, mod, grammar, target, optimize);
    }

    const pcre2 = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    mod.linkLibrary(pcre2.artifact("pcre2-8"));

    const tree_sitter_tql = b.dependency("tree-sitter-tql", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(tree_sitter_tql.path("src"));
    mod.addCSourceFiles(.{
        .root = tree_sitter_tql.path(""),
        .files = &.{"src/parser.c"},
        .flags = &.{ "-std=c11", "-fPIC" },
    });
}

fn validGrammarNames(b: *std.Build) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(b.allocator);
    for (grammars, 0..) |g, i| {
        if (i > 0) try buf.appendSlice(b.allocator, ", ");
        try buf.appendSlice(b.allocator, g.outName());
    }
    return buf.toOwnedSlice(b.allocator);
}

const GrammarSelection = union(enum) {
    available,
    subset: []const []const u8,
    none,
};

fn parseGrammarNames(b: *std.Build, str: []const u8) !GrammarSelection {
    if (std.mem.eql(u8, str, "none")) return .none;
    if (std.mem.eql(u8, str, "available")) return .available;
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, str, ',');
    while (it.next()) |name| {
        if (name.len > 0) try result.append(b.allocator, name);
    }
    return .{ .subset = try result.toOwnedSlice(b.allocator) };
}

fn selectionNames(b: *std.Build, sel: GrammarSelection) ![]const []const u8 {
    return switch (sel) {
        .none => &.{},
        .available => blk: {
            const names = try b.allocator.alloc([]const u8, grammars.len);
            for (grammars, 0..) |g, i| names[i] = g.outName();
            break :blk names;
        },
        .subset => |names| names,
    };
}

fn selectedGrammars(
    b: *std.Build,
    sel: GrammarSelection,
) ![]const TreeSitterGrammar {
    return switch (sel) {
        .none => &.{},
        .available => b.allocator.dupe(TreeSitterGrammar, grammars),
        .subset => |names| blk: {
            var seen: std.ArrayListUnmanaged(bool) = .empty;
            defer seen.deinit(b.allocator);
            try seen.appendNTimes(b.allocator, false, grammars.len);

            var result: std.ArrayList(TreeSitterGrammar) = .empty;
            for (names) |name| {
                var found_idx: ?usize = null;
                for (grammars, 0..) |g, i| {
                    if (std.mem.eql(u8, g.outName(), name)) {
                        found_idx = i;
                        break;
                    }
                }
                if (found_idx == null) {
                    const valid = try validGrammarNames(b);
                    defer b.allocator.free(valid);
                    std.debug.print(
                        "error: unknown grammar '{s}'. Valid names: {s}\n",
                        .{ name, valid },
                    );
                    return error.UnknownGrammar;
                }
                const idx = found_idx.?;
                if (!seen.items[idx]) {
                    seen.items[idx] = true;
                    try result.append(b.allocator, grammars[idx]);
                }
            }
            break :blk result.toOwnedSlice(b.allocator);
        },
    };
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).

pub fn build(b: *std.Build) !void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const goz = b.dependency("goz", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("tql_engine_zig", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "tql",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "tql_engine_zig" is the name you will use in your source code to
                // import this module (e.g. `@import("tql_engine_zig")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "tql_engine_zig", .module = mod },
                .{ .name = "goz", .module = goz.module("goz") },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    const grammars_str = b.option([]const u8, "grammars", "Comma-separated grammar names to build into the binary, 'available' for all, or 'none' (default)") orelse "none";
    const selection = try parseGrammarNames(b, grammars_str);
    const selected = try selectedGrammars(b, selection);
    const selected_names = try selectionNames(b, selection);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", VERSION);
    build_options.addOption([]const []const u8, "static_grammars", selected_names);
    mod.addOptions("build_options", build_options);

    try addEngineDeps(b, mod, selected, target, optimize);

    const grammars_step = b.step("grammars", "Build shared libraries for the selected grammars");
    for (selected) |g| {
        const lib = try buildGrammarSharedLib(b, g, target, optimize);
        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = "lib/tql/grammars" } },
        });
        grammars_step.dependOn(&install.step);
    }

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const wasm_mod = b.addModule("tql_engine_zig_wasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    wasm_mod.addOptions("build_options", build_options);
    try addEngineDeps(b, wasm_mod, selected, wasm_target, wasm_optimize);

    const wasm_exe = b.addExecutable(.{
        .name = "tql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{
                .{ .name = "tql_engine_zig", .module = wasm_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_step = b.step("wasm", "Build the wasm artifact");
    const wasm_install = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&wasm_install.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const forced_grammars = try selectedGrammars(b, .{ .subset = &.{ "c", "typescript" } });

    const test_build_options = b.addOptions();
    test_build_options.addOption([]const u8, "version", VERSION);

    const test_mod = b.addModule("tql_engine_zig_test", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_build_options);
    try addEngineDeps(b, test_mod, forced_grammars, target, optimize);

    const mod_tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = b.path("tests/test_runner.zig"), .mode = .simple },
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const snapshot_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/snapshot_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_runner_mod.addImport("engine", test_mod);
    const snapshot_runner_exe = b.addExecutable(.{
        .name = "snapshot-runner",
        .root_module = snapshot_runner_mod,
    });
    const run_snapshot_runner = b.addRunArtifact(snapshot_runner_exe);
    if (b.args) |args| run_snapshot_runner.addArgs(args);
    const snapshot_test_step = b.step("snapshot-test", "Run inline corpus snapshot tests");
    snapshot_test_step.dependOn(&run_snapshot_runner.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
