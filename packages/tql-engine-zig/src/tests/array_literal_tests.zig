const Snapshotter = @import("snapshotter.zig");

test "single variable" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class
        \\select [ @class ]
        ,
        .target = "class Foo {}",
    });
}

test "mixed" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class
        \\select [ 'class', @class ]
        ,
        .target = "class Foo {}",
    });
}

test "multiple matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class
        \\select [ @class ]
        ,
        .target =
        \\class A {}
        \\class B {}
        ,
    });
}
