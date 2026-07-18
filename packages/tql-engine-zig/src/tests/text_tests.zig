const Snapshotter = @import("snapshotter.zig");

test "text() extracts node text" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. >> property_identifier | text()
        ,
        .target =
        \\class Foo { bar() {} }
        ,
    });
}

test "bare text extracts node text" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. >> property_identifier | text
        ,
        .target =
        \\class Foo { bar() {} }
        ,
    });
}

test "text via variable" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. >> property_identifier as @id | @id | text
        ,
        .target =
        \\class Foo { bar() {} }
        ,
    });
}

test "string comparison still works after text() added" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\. >> property_identifier as @id | select(@id | text = 'bar') | @id
        ,
        .target =
        \\class Foo { bar() {} }
        ,
    });
}
