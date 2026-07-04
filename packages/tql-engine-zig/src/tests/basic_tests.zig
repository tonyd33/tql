const Snapshotter = @import("snapshotter.zig");

test "node selector" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @class | @class
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\function foo() {}
        ,
    });
}

test "field access" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @c | @c.name as @n | @n
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "child navigation" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration > class_body as @body | @body > method_definition as @m | @m
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
    });
}
