const Snapshotter = @import("snapshotter.zig");

test "regex match simple" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @c | @c.name as @n | select(@n ~ /Service/) | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
    });
}

test "regex match anchored" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @c | @c.name as @n | select(@n ~ /^Service$/) | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
    });
}

test "regex not match" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @c | @c.name as @n | select(@n !~ /Service/) | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
    });
}

test "regex match character class" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\@root > class_declaration as @c | @c.name as @n | select(@n ~ /[A-Z][a-z]+/) | @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class foo {}
        ,
    });
}
