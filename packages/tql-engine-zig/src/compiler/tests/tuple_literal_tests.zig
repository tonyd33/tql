const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

test "select tuple_literal: pair" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select ('class', @class)
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/compiler/tests/snapshots/select_tuple_pair.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select tuple_literal: triple" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  select ('class', @name, @class)
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/compiler/tests/snapshots/select_tuple_triple.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
