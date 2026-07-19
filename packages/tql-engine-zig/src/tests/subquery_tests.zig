const Snapshotter = @import("snapshotter.zig");

test "subquery in select projects list per outer match" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func | [@func.declarator.parameters > parameter_declaration]
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery empty produces empty list" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func | [@func > goto_statement]
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "collect dot refers to piped-in value" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition | { fn: ., params: [. >> parameter_declaration] }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery captures outer binding" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition.declarator as @func_decl | {
        \\  name: @func_decl.declarator,
        \\  params: [@func_decl.parameters > parameter_declaration as @p | @p]
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "nested subquery" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func | {
        \\  fn: @func,
        \\  param_lists: [
        \\    @func.declarator as @decl |
        \\    [@decl.parameters > parameter_declaration as @p | @p]
        \\  ]
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "subquery with where clause filters inner stream" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func | {
        \\  fn: @func,
        \\  int_params: [
        \\    @func.declarator.parameters > parameter_declaration as @p |
        \\    @p.type as @t |
        \\    select(@t | text = 'int') |
        \\    @p
        \\  ]
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery as binding produces list per outer fanout" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition.declarator as @func_decl |
        \\[@func_decl.parameters > parameter_declaration as @p | @p] as @param_decl |
        \\@func_decl.declarator as @func_name |
        \\{ name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery binding without rebinding fans out (baseline)" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition.declarator as @func_decl |
        \\@func_decl.parameters > parameter_declaration as @param_decl |
        \\@func_decl.declarator as @func_name |
        \\{ name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "unnest restores fanout from subquery binding" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition.declarator as @func_decl |
        \\unnest([@func_decl.parameters > parameter_declaration]) as @param_decl |
        \\@func_decl.declarator as @func_name |
        \\{ name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "unnest restores fanout from subquery binding with inner binds" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition.declarator as @func_decl |
        \\unnest([
        \\  @func_decl.parameters as @params |
        \\  @params > parameter_declaration
        \\]) as @param_decl |
        \\@func_decl.declarator as @func_name |
        \\{ name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "unnest on empty subquery drops branch" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func |
        \\unnest([@func > goto_statement]) as @g |
        \\{ fn: @func, g: @g }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "unnest of singleton list yields one fanout" {
    try Snapshotter.snapshotQuery(@src(), .{
        .grammar = "c",
        .query =
        \\. > function_definition as @func |
        \\unnest([@func.declarator]) as @d |
        \\{ @func, @d }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}
