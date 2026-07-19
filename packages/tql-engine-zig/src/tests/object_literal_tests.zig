const Snapshotter = @import("snapshotter.zig");

test "shorthand" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | { @class }
        ,
        .target = "class Foo {}",
    });
}

test "two shorthand fields" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | @class.name as @name | { @class, @name }
        ,
        .target = "class Foo {}",
    });
}

test "key value" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | { kind: 'class', node: @class }
        ,
        .target = "class Foo {}",
    });
}

test "multiple matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | { @class }
        ,
        .target =
        \\class A {}
        \\class B {}
        \\class C {}
        ,
    });
}
