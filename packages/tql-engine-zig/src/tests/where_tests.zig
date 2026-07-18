const Snapshotter = @import("snapshotter.zig");

test "WHERE with simple comparison" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c.name as @n | select(@n | text = 'Service') | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "WHERE with OR logic" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | @c.name as @n | select(@n | text = 'Service' or @n | text = 'Controller') | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE with AND logic" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c |
        \\@c.name as @class_name |
        \\@c.body as @body |
        \\@body > method_definition as @method_def |
        \\@method_def.name as @method_name |
        \\select(@class_name | text = 'Service' and @method_name | text = 'foo') |
        \\@c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { foo() {}; bar() {}; }
        ,
    });
}

test "WHERE with any quantifier - matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name | text = 'foo')) | @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}

test "WHERE with any quantifier - no matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name | text = 'nonexistent')) | @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}

test "WHERE any matches second method only" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name | text = 'foo')) | @c
        ,
        .target =
        \\class A { bar() {}; foo() {}; }
        \\class B { bar() {}; baz() {}; }
        ,
    });
}

test "WHERE with all quantifier" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(all(@c.body > method_definition; .name | text = 'foo')) | @c
        ,
        .target =
        \\class A { foo() {}; foo() {}; }
        \\class B { foo() {}; bar() {}; }
        ,
    });
}

test "WHERE field access on outer row" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(@c.name | text = 'Service') | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "WHERE optional binding is null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > function_declaration as @f | @f.return_type as @rt? | select(@rt = null) | @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE optional binding is not null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > function_declaration as @f | @f.return_type as @rt? | select(@rt != null) | @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE expression is null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > function_declaration as @f | select(@f.return_type is null) | @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE expression is not null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > function_declaration as @f | select(@f.return_type is not null) | @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE field access with regex match" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name | text ~ /^foo.*/)) | @c
        ,
        .target =
        \\class A { foobar() {}; }
        \\class B { bar() {}; }
        ,
    });
}

test "WHERE field access with not equal" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(@c.name | text != 'Service') | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE field access in AND" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(@c.name | text = 'Service' and any(@c.body > method_definition; .name | text = 'foo')) | @c
        ,
        .target =
        \\class Service { foo() {}; }
        \\class Service { bar() {}; }
        \\class Other { foo() {}; }
        ,
    });
}

test "WHERE same field accessed twice" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(@c.name | text = 'Service' or @c.name | text = 'Controller') | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE quantified regression for double yield" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c |
        \\@c.name as @class_name |
        \\select(@class_name | text ~ /Foo.*/ and any(@c.body > method_definition; .return_type != null)) |
        \\{ @class_name }
        ,
        .target =
        \\class Foo1 {
        \\  m1(): string {}
        \\  m2() {}
        \\  m3(): number {}
        \\}
        \\
        \\class Foo2 {}
        \\
        \\class Foo3 {
        \\  m3() {}
        \\}
        ,
    });
}

test "WHERE descendant nav in quantifier source" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c >> method_definition; .name | text = 'foo')) | @c
        ,
        .target =
        \\class Service { foo() {}; }
        \\class Controller { bar() {}; }
        ,
    });
}

test "WHERE child nav in comparison body" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .body > return_statement != null)) | @c
        ,
        .target =
        \\class A { foo() { return 1; } }
        \\class B { bar() {} }
        ,
    });
}

test "WHERE field access in OR with anonymous lift" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name | text = 'foo' or .name | text = 'bar')) | @c
        ,
        .target =
        \\class A { foo() {}; }
        \\class B { bar() {}; }
        \\class C { baz() {}; }
        ,
    });
}

test "WHERE any with not-null body" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @c | select(any(@c.body > method_definition; .name != null)) | @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}
