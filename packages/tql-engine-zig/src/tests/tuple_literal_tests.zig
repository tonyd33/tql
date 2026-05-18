const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "tuple_literal");

test "select tuple_literal: pair" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select ('class', @class)
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_tuple_pair",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select tuple_literal: triple" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  select ('class', @name, @class)
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_tuple_triple",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
