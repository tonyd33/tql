const Snapshotter = @import("snapshotter.zig");

// Group 1: Identity passthrough

test "dot identity at top level" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. | .
        ,
        .target =
        \\class Foo {}
        ,
    });
}

test "dot identity in middle of pipeline" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | . | .name as @n | @n
        ,
        .target =
        \\class Foo {}
        ,
    });
}

// Group 2: . is identity — equivalent to the previous transform step

test "dot identity after variable transform" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | .
        ,
        .target =
        \\class Foo {}
        \\class Bar {}
        ,
    });
}

test "dot identity after field access transform" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c.name | .
        ,
        .target =
        \\class Foo {}
        \\class Bar {}
        ,
    });
}

test "chained dot identity" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | . | .
        ,
        .target =
        \\class Foo {}
        \\class Bar {}
        ,
    });
}

// Group 3: . as @v — bind current value to name

test "dot bind to variable" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | . as @snap | @snap
        ,
        .target =
        \\class Foo {}
        \\class Bar {}
        ,
    });
}

// Group 4: .field navigates current value in pipeline

test "dot field access on current value" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | .name
        ,
        .target =
        \\class Foo {}
        \\class Bar {}
        ,
    });
}

test "dot field access after function transform" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > function_declaration as @f | @f | .name
        ,
        .target =
        \\function foo() {}
        \\function bar() {}
        ,
    });
}

// Group 5: . inside quantifiers (regression guards)

test "dot in any quantifier predicate" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name = 'foo')) | @c
        ,
        .target =
        \\class A { foo() {}; }
        \\class B { bar() {}; }
        ,
    });
}

test "dot field in any predicate" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name ~ /^foo/)) | @c
        ,
        .target =
        \\class A { foobar() {}; }
        \\class B { bar() {}; }
        ,
    });
}

test "bare dot in any predicate" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; . != null)) | @c
        ,
        .target =
        \\class A { foo() {}; }
        \\class B {}
        ,
    });
}

// Group 6: . in projection

test "dot in object literal projection" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | { name: .name }
        ,
        .target =
        \\class Foo {}
        ,
    });
}

// Group 7: .field in select() predicate after transform step

test "dot field in select predicate after transform" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | select(.name ~ /Controller/) | .
        ,
        .target =
        \\class FooController {}
        \\class Bar {}
        ,
    });
}

test "dot field select then dot field project" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c | select(.name ~ /Controller/) | .name
        ,
        .target =
        \\class FooController {}
        \\class Bar {}
        ,
    });
}
