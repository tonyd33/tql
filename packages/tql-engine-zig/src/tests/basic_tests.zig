const Snapshotter = @import("snapshotter.zig");

test "node selector" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\query main() {
        \\  with class_declaration as @class
        \\  select @class
        \\}
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
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  select @n
        \\}
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
        \\query main() {
        \\  with class_declaration > class_body as @body,
        \\       @body > method_definition as @m
        \\  select @m
        \\}
        ,
        .target =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
    });
}
