const Snapshotter = @import("snapshotter.zig");

test "pair" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class
        \\select ('class', @class)
        ,
        .target = "class Foo {}",
    });
}

test "triple" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class,
        \\     @class.name as @name
        \\select ('class', @name, @class)
        ,
        .target = "class Foo {}",
    });
}
