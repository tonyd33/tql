const Snapshotter = @import("snapshotter.zig");

test "regex match simple" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /Service/
        \\  select @c
        \\}
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
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /^Service$/
        \\  select @c
        \\}
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
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  where @n !~ /Service/
        \\  select @c
        \\}
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
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /[A-Z][a-z]+/
        \\  select @c
        \\}
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class foo {}
        ,
    });
}
