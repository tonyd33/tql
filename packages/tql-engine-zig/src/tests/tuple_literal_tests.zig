const Snapshotter = @import("snapshotter.zig");

test "pair" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | ('class', @class)
        ,
        .target = "class Foo {}",
    });
}

test "triple" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. > class_declaration as @class | @class.name as @name | ('class', @name, @class)
        ,
        .target = "class Foo {}",
    });
}
