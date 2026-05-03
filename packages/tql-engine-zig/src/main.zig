const std = @import("std");
const tql = @import("tql_engine_zig");
const clap = @import("clap");
const Engine = tql.Engine;
const Language = tql.Language;

const VERSION = "0.1.0";

const OutputFormat = enum {
    text,
    json,
    locations,
};

const CliLanguage = enum {
    c,
    typescript,
    tsx,

    fn toLanguage(self: CliLanguage) Language {
        return switch (self) {
            .c => .c,
            .typescript => .typescript,
            .tsx => .tsx,
        };
    }
};

const ExitCode = enum(u8) {
    success = 0,
    no_matches = 1,
    parse_error = 2,
    compilation_error = 3,
    runtime_error = 4,
    invalid_args = 5,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-v, --version               Display version and exit.
        \\-l, --language <language>   Source language (c, typescript, tsx).
        \\-f, --format <format>       Output format (text, json, locations).
        \\-w, --workers <usize>       Number of workers
        \\    --no-source             Don't include source text in output.
        \\    --captures              Include variable captures/bindings.
        \\    --max-matches <usize>   Stop after N matches.
        \\    --dump-ast              Print parsed query AST and exit.
        \\    --dump-instructions     Print compiled bytecode and exit.
        \\    --stats                 Print runtime statistics.
        \\    --verbose               Verbose output.
        \\<file>...
        \\
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .language = clap.parsers.enumeration(CliLanguage),
        .format = clap.parsers.enumeration(OutputFormat),
        .usize = clap.parsers.int(usize, 10),
        .file = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        try stderr.flush();
        return @intFromEnum(ExitCode.invalid_args);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{
            .description_on_new_line = false,
            .spacing_between_parameters = 0,
        });
        return @intFromEnum(ExitCode.success);
    }

    if (res.args.version != 0) {
        try printVersion(stdout);
        return @intFromEnum(ExitCode.success);
    }

    const files = res.positionals[0];
    if (files.len < 2) {
        try stderr.print("Error: Expected at least 2 arguments (query file and source file)\n", .{});
        try printUsage(stderr);
        return @intFromEnum(ExitCode.invalid_args);
    }

    const query_path = files[0];
    const source_paths = files[1..];

    return run(allocator, stdout, stderr, .{
        .query_path = query_path,
        .source_paths = source_paths,
        .language = if (res.args.language) |l| l.toLanguage() else null,
        .format = res.args.format orelse .text,
        .workers = res.args.workers,
        .no_source = res.args.@"no-source" != 0,
        .captures = res.args.captures != 0,
        .max_matches = res.args.@"max-matches",
        .dump_ast = res.args.@"dump-ast" != 0,
        .dump_instructions = res.args.@"dump-instructions" != 0,
        .stats = res.args.stats != 0,
        .verbose = res.args.verbose != 0,
    }) catch |err| {
        try stderr.print("Error: {}\n", .{err});
        return @intFromEnum(ExitCode.runtime_error);
    };
}

const Config = struct {
    query_path: []const u8,
    source_paths: []const []const u8,
    language: ?Language,
    format: OutputFormat,
    workers: ?usize,
    no_source: bool,
    captures: bool,
    max_matches: ?usize,
    dump_ast: bool,
    dump_instructions: bool,
    stats: bool,
    verbose: bool,
};

fn run(
    allocator: std.mem.Allocator,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    config: Config,
) !u8 {
    if (config.source_paths.len > 1) {
        try stderr.print("Only one file supported right now\n", .{});
        return @intFromEnum(ExitCode.invalid_args);
    }
    const source_path = config.source_paths[0];

    const query_source = try std.fs.cwd().readFileAlloc(allocator, config.query_path, 1024 * 1024);
    defer allocator.free(query_source);

    var engine = try Engine.init(.{
        .allocator = allocator,
        .max_threads = config.workers,
    });
    defer engine.deinit();

    if (config.dump_ast) {
        const source_file = try engine.parseQuery(query_source);
        defer source_file.deinit(allocator);

        if (source_file.items.len == 0) {
            try stderr.print("No query definitions found\n", .{});
            return @intFromEnum(ExitCode.parse_error);
        }

        const query_def = switch (source_file.items[0]) {
            .query => |q| q,
            else => {
                try stderr.print("First item is not a query\n", .{});
                return @intFromEnum(ExitCode.parse_error);
            },
        };

        try dumpAst(stdout, query_def);
        return @intFromEnum(ExitCode.success);
    }

    // FIXME: We shouldn't need this
    const language = if (config.language) |lang|
        lang
    else
        Language.fromPath(config.source_paths[0]) orelse {
            try stderr.print("Cannot detect language from '{s}'. Use --language to specify.\n", .{config.source_paths[0]});
            return @intFromEnum(ExitCode.invalid_args);
        };

    const compile_result = engine.compileTql(query_source, language) catch |err| {
        try stderr.print("Failed to compile query: {}\n", .{err});
        return @intFromEnum(ExitCode.compilation_error);
    };
    var compiled_query = compile_result.query;
    defer compiled_query.deinit();

    if (config.stats) {
        try printCompileStats(stderr, compile_result.stats);
    }

    if (config.verbose) {
        try stderr.print("Compiled query for {s} ({d} instructions, {d}µs)\n", .{
            language.name(),
            compile_result.stats.instruction_count,
            compile_result.stats.compile_time_us,
        });
    }

    if (config.dump_instructions) {
        try dumpInstructions(stdout, compiled_query.program.instructions);
        return @intFromEnum(ExitCode.success);
    }

    const file = try std.fs.cwd().openFile(source_path, .{});
    defer file.close();

    // IMPROVE: prolly mmap'ing the file is more efficient
    const source_code = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(source_code);

    var query_result = try compiled_query.run(source_code);
    defer query_result.deinit();

    try formatResult(stdout, allocator, query_result);
    return 0;
}

fn formatResult(writer: *std.io.Writer, allocator: std.mem.Allocator, result: tql.QueryResult) !void {
    var jws = std.json.Stringify{ .writer = writer };

    try jws.beginArray();
    for (result.matches, 0..) |match, i| {
        const capture_count = match.captures.count();
        const keys = try allocator.alloc([]const u8, capture_count);
        defer allocator.free(keys);
        const values = try allocator.alloc(tql.Value, capture_count);
        defer allocator.free(values);

        var iter = match.captures.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| : (idx += 1) {
            keys[idx] = entry.key_ptr.*;
            values[idx] = entry.value_ptr.*;
        }
        var hmu = try std.StringArrayHashMapUnmanaged(tql.Value).init(
            allocator,
            keys,
            values,
        );
        defer hmu.deinit(allocator);
        const captures_map = std.json.ArrayHashMap(tql.Value){ .map = hmu };

        try jws.beginObject();

        try jws.objectField("index");
        try jws.write(i);

        try jws.objectField("node");
        try jws.write(match.node);

        try jws.objectField("captures");
        try captures_map.jsonStringify(&jws);

        try jws.endObject();
    }
    try jws.endArray();
}

fn dumpAst(writer: *std.io.Writer, query_def: tql.AST.QueryDefinition) anyerror!void {
    try writer.print("QueryDefinition {{\n", .{});
    try writer.print("  name: \"{s}\"\n", .{query_def.name});

    if (query_def.parameters.len > 0) {
        try writer.print("  parameters: [\n", .{});
        for (query_def.parameters) |param| {
            try writer.print("    {{ name: @{s}, type: ", .{param.name.name});
            if (param.type) |t| {
                try dumpType(writer, t);
            } else {
                try writer.print("null", .{});
            }
            try writer.print(" }}\n", .{});
        }
        try writer.print("  ]\n", .{});
    }

    if (query_def.return_type) |ret_type| {
        try writer.print("  return_type: ", .{});
        try dumpType(writer, ret_type);
        try writer.print("\n", .{});
    }

    try writer.print("  body: ", .{});
    try dumpQueryBody(writer, query_def.body, 2);
    try writer.print("}}\n", .{});
}

fn dumpQueryBody(writer: *std.io.Writer, body: tql.AST.QueryBody, indent: usize) anyerror!void {
    try writer.print("{{\n", .{});

    if (body.from_clause) |from| {
        try writeIndent(writer, indent + 2);
        try writer.print("from: [\n", .{});
        for (from.bindings) |binding| {
            try writeIndent(writer, indent + 4);
            try writer.print("{{ ", .{});
            try dumpNavigationExpression(writer, binding.expression);
            try writer.print(" as @{s}", .{binding.variable.name});
            if (binding.optional) {
                try writer.print("?", .{});
            }
            try writer.print(" }}\n", .{});
        }
        try writeIndent(writer, indent + 2);
        try writer.print("]\n", .{});
    }

    if (body.where_clause) |where| {
        try writeIndent(writer, indent + 2);
        try writer.print("where: ", .{});
        try dumpPredicate(writer, where.predicate);
        try writer.print("\n", .{});
    }

    try writeIndent(writer, indent + 2);
    try writer.print("select: ", .{});
    try dumpProjection(writer, body.select_clause.projection);
    try writer.print("\n", .{});

    try writeIndent(writer, indent);
    try writer.print("}}", .{});
}

fn dumpNavigationExpression(writer: *std.io.Writer, expr: tql.AST.NavigationExpression) anyerror!void {
    try writer.print("(", .{});
    switch (expr) {
        .node_selector => |ns| try writer.print("{s}", .{ns.node_type}),
        .variable => |v| try writer.print("@{s}", .{v.name}),
        .field_access => |fa| {
            try dumpNavigationExpression(writer, fa.base);
            try writer.print(".{s}", .{fa.field});
        },
        .child_navigation => |cn| {
            try dumpNavigationExpression(writer, cn.parent);
            try writer.print(" > ", .{});
            try dumpNavigationExpression(writer, cn.child);
        },
        .descendant_navigation => |dn| {
            try dumpNavigationExpression(writer, dn.parent);
            try writer.print(" >> ", .{});
            try dumpNavigationExpression(writer, dn.descendant);
        },
        .query_call => |qc| {
            try writer.print("{s}(", .{qc.name});
            for (qc.arguments, 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpExpression(writer, arg);
            }
            try writer.print(")", .{});
        },
        .parenthesized => |p| {
            try writer.print("(", .{});
            try dumpNavigationExpression(writer, p.*);
            try writer.print(")", .{});
        },
    }
    try writer.print(")", .{});
}

fn dumpPredicate(writer: *std.io.Writer, pred: tql.AST.Predicate) anyerror!void {
    switch (pred) {
        .comparison => |c| {
            try writer.print("(", .{});
            try dumpExpression(writer, c.left);
            try writer.print(" {s} ", .{@tagName(c.operator)});
            try dumpExpression(writer, c.right);
            try writer.print(")", .{});
        },
        .logical_and => |la| {
            try writer.print("(", .{});
            try dumpPredicate(writer, la.left);
            try writer.print(" AND ", .{});
            try dumpPredicate(writer, la.right);
            try writer.print(")", .{});
        },
        .logical_or => |lo| {
            try writer.print("(", .{});
            try dumpPredicate(writer, lo.left);
            try writer.print(" OR ", .{});
            try dumpPredicate(writer, lo.right);
            try writer.print(")", .{});
        },
        .logical_not => |ln| {
            try writer.print("(NOT ", .{});
            try dumpPredicate(writer, ln.predicate);
            try writer.print(")", .{});
        },
        .quantified => |q| {
            try writer.print("({s} @{s}: ", .{ @tagName(q.quantifier), q.variable.name });
            try dumpPredicate(writer, q.predicate.*);
            try writer.print(")", .{});
        },
        .variable => |v| try writer.print("@{s}", .{v.name}),
        .parenthesized => |p| {
            try writer.print("(", .{});
            try dumpPredicate(writer, p.*);
            try writer.print(")", .{});
        },
    }
}

fn dumpExpression(writer: *std.io.Writer, expr: tql.AST.Expression) anyerror!void {
    switch (expr) {
        .variable => |v| try writer.print("@{s}", .{v.name}),
        .string_literal => |s| try writer.print("'{s}'", .{s}),
        .regex_literal => |r| try writer.print("/{s}/", .{r}),
        .number_literal => |n| try writer.print("{d}", .{n}),
        .function_call => |fc| {
            try writer.print("{s}(", .{fc.name});
            for (fc.arguments, 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpExpression(writer, arg);
            }
            try writer.print(")", .{});
        },
        .field_access => |fa| {
            try dumpExpression(writer, fa.base);
            try writer.print(".{s}", .{fa.field});
        },
        .subquery => |sq| {
            try writer.print("(", .{});
            try dumpQueryBody(writer, sq.*, 0);
            try writer.print(")", .{});
        },
    }
}

fn dumpProjection(writer: *std.io.Writer, proj: tql.AST.Projection) anyerror!void {
    switch (proj) {
        .variable => |v| try writer.print("@{s}", .{v.name}),
        .string_literal => |s| try writer.print("'{s}'", .{s}),
        .regex_literal => |r| try writer.print("/{s}/", .{r}),
        .number_literal => |n| try writer.print("{d}", .{n}),
        .function_call => |fc| {
            try writer.print("{s}(", .{fc.name});
            for (fc.arguments, 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpExpression(writer, arg);
            }
            try writer.print(")", .{});
        },
        .field_access => |fa| {
            try dumpExpression(writer, fa.base);
            try writer.print(".{s}", .{fa.field});
        },
        .object_literal => |ol| {
            try writer.print("{{ ", .{});
            for (ol.fields, 0..) |field, i| {
                if (i > 0) try writer.print(", ", .{});
                switch (field) {
                    .key_value => |kv| {
                        try writer.print("{s}: ", .{kv.key});
                        try dumpExpression(writer, kv.value);
                    },
                    .variable => |v| try writer.print("@{s}", .{v.name}),
                }
            }
            try writer.print(" }}", .{});
        },
        .array_literal => |al| {
            try writer.print("[", .{});
            for (al.elements, 0..) |elem, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpExpression(writer, elem);
            }
            try writer.print("]", .{});
        },
        .tuple_literal => |tl| {
            try writer.print("(", .{});
            for (tl.elements, 0..) |elem, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpExpression(writer, elem);
            }
            try writer.print(")", .{});
        },
        .subquery => |sq| {
            try writer.print("(", .{});
            try dumpQueryBody(writer, sq.*, 0);
            try writer.print(")", .{});
        },
    }
}

fn dumpType(writer: *std.io.Writer, t: tql.AST.Type) anyerror!void {
    switch (t) {
        .identifier => |id| try writer.print("{s}", .{id}),
        .builtin => |b| try writer.print("{s}", .{@tagName(b)}),
        .array => |a| {
            try writer.print("Array<", .{});
            try dumpType(writer, a.element_type.*);
            try writer.print(">", .{});
        },
        .object => |o| {
            try writer.print("Object<", .{});
            try dumpType(writer, o.value_type.*);
            try writer.print(">", .{});
        },
        .tuple => |tup| {
            try writer.print("(", .{});
            for (tup.element_types, 0..) |elem_type, i| {
                if (i > 0) try writer.print(", ", .{});
                try dumpType(writer, elem_type);
            }
            try writer.print(")", .{});
        },
        .optional => |opt| {
            try dumpType(writer, opt.*);
            try writer.print("?", .{});
        },
    }
}

fn writeIndent(writer: *std.io.Writer, indent: usize) anyerror!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try writer.print(" ", .{});
    }
}

fn dumpInstructions(writer: *std.io.Writer, instructions: []const tql.Runtime.Instruction) !void {
    for (instructions, 0..) |inst, i| {
        try writer.print("{d}: ", .{i});
        try formatInstruction(writer, inst);
        try writer.print("\n", .{});
    }
}

fn formatInstruction(writer: *std.io.Writer, inst: tql.Runtime.Instruction) !void {
    switch (inst) {
        .noop => try writer.print("noop", .{}),
        .yield => try writer.print("yield", .{}),
        .halt => |h| try writer.print("halt {s}", .{@tagName(h.condition)}),
        .trv => |t| {
            try writer.print("trv ", .{});
            switch (t) {
                .child => try writer.print("child", .{}),
                .descendant => try writer.print("descendant", .{}),
                .field => |f| try writer.print("field {}", .{f}),
                .variable_id => |v| try writer.print("variable_id {}", .{v}),
            }
        },
        .asn => |a| {
            try writer.print("asn {} (", .{a.variable_id});
            try formatValueSource(writer, a.source);
            try writer.print(")", .{});
        },
        .rel => |r| {
            try writer.print("rel {s} (", .{@tagName(r.relation)});
            try formatValueSource(writer, r.a);
            try writer.print(") (", .{});
            try formatValueSource(writer, r.b);
            try writer.print(")", .{});
        },
        .probe => |p| try writer.print("probe {s} {}", .{ @tagName(p.mode), p.on_success }),
        .call => |c| try writer.print("call {}", .{c}),
        .ret => try writer.print("ret", .{}),
        .jmp => |j| try writer.print("jmp {s} {}", .{ @tagName(j.mode), j.address }),
        .panic => try writer.print("panic", .{}),
    }
}

fn formatValueSource(writer: *std.io.Writer, source: tql.Runtime.ValueSource) !void {
    switch (source) {
        .literal => |l| {
            try writer.print("literal ", .{});
            switch (l) {
                .nothing => try writer.print("nothing", .{}),
                .string => |s| try writer.print("string \"{s}\"", .{s}),
                .kind_id => |k| try writer.print("kind_id {}", .{k}),
                .field_id => |f| try writer.print("field_id {}", .{f}),
                .range => try writer.print("range ...", .{}),
                .node => try writer.print("node ...", .{}),
                .regex => try writer.print("regex ...", .{}),
            }
        },
        .node => |n| try writer.print("node {s}", .{@tagName(n)}),
        .variable_id => |v| try writer.print("variable_id {}", .{v}),
    }
}

fn printCompileStats(writer: *std.io.Writer, stats: tql.CompileStats) !void {
    try writer.print("\n--- Compile Statistics ---\n", .{});
    try writer.print("Parse time: {d}µs\n", .{stats.parse_time_us});
    try writer.print("Compile time: {d}µs\n", .{stats.compile_time_us});
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print("Usage: tql [OPTIONS] <QUERY> <SOURCE>...\n", .{});
    try writer.print("Try 'tql --help' for more information.\n", .{});
}

fn printVersion(writer: *std.io.Writer) !void {
    try writer.print("tql version {s}\n", .{VERSION});
}
