const Snapshotter = @import("snapshotter.zig");

test "nested field access" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     (@c.body > method_definition).name as @nested_name
        \\select @nested_name
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\}
        ,
    });
}

test "field access on node selector" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with (@root > class_declaration).name as @name
        \\select @name
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "child navigation with field access parent" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     @c.body > method_definition as @method
        \\select @method
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
    });
}

test "child navigation on node selector" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with (@root > class_declaration).body > method_definition as @method
        \\select @method
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        \\class Controller {
        \\  baz() {}
        \\}
        ,
    });
}

test "descendant navigation with field access parent" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     @c.body >> property_identifier as @id
        \\select @id
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
    });
}

test "descendant navigation on node selector" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with (@root > class_declaration) >> property_identifier as @id
        \\select @id
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\}
        \\class Controller {
        \\  bar() {}
        \\}
        ,
    });
}

test "nested child navigation" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     (@c > class_body) > method_definition as @method
        \\select @method
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
    });
}
