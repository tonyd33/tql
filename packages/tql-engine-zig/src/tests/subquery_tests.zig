const Snapshotter = @import("snapshotter.zig");

test "subquery in select projects list per outer match" {
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func
        \\select ( select @func.declarator.parameters > parameter_declaration )
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery empty produces empty list" {
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func
        \\select ( select @func > goto_statement )
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "subquery shares root with enclosing scope" {
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func
        \\select { fn: @func, all_funcs: select @root > function_definition }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery captures outer binding" {
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition.declarator as @func_decl
        \\select {
        \\  name: @func_decl.declarator,
        \\  params: select @func_decl.parameters > parameter_declaration
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "nested subquery" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func
        \\select {
        \\  fn: @func,
        \\  param_lists: (
        \\    with @func.declarator as @decl
        \\    select (select @decl.parameters > parameter_declaration)
        \\  )
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "subquery with where clause filters inner stream" {
    if (1 == 1) return error.SkipZigTest;
    // where in subquery scopes to the subquery's bindings only.
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func
        \\select {
        \\  fn: @func,
        \\  int_params:
        \\    with @func.declarator.parameters > parameter_declaration as @p,
        \\         @p.type as @t
        \\    where @t == "int"
        \\    select @p
        \\
        \\}
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery as binding produces list per outer fanout" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition.declarator as @func_decl,
        \\     select @func_decl.parameters > parameter_declaration as @param_decl,
        \\     @func_decl.declarator as @func_name
        \\select { name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "subquery binding without rebinding fans out (baseline)" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition.declarator as @func_decl,
        \\     @func_decl.parameters > parameter_declaration as @param_decl,
        \\     @func_decl.declarator as @func_name
        \\select { name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "unnest restores fanout from subquery binding" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition.declarator as @func_decl,
        \\     unnest(select @func_decl.parameters > parameter_declaration) as @param_decl,
        \\     @func_decl.declarator as @func_name
        \\select { name: @func_name, param: @param_decl }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        \\int main(void) { return 0; }
        ,
    });
}

test "unnest on empty subquery drops branch" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func,
        \\     unnest(select @func > goto_statement) as @g
        \\select { fn: @func, g: @g }
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}

test "unnest of singleton list yields one fanout" {
    if (1 == 1) return error.SkipZigTest;
    try Snapshotter.snapshotQuery(@src(), .{
        .language = .c,
        .query =
        \\with @root > function_definition as @func,
        \\     unnest(select @func.declarator) as @d
        \\select @d
        ,
        .target =
        \\int add(int a, int b) { return a + b; }
        ,
    });
}
