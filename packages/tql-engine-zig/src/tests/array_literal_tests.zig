const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

test "select array_literal: single variable" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select [ @class ]
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/tests/snapshots/select_array_single.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select array_literal: mixed" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select [ 'class', @class ]
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/tests/snapshots/select_array_mixed.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select array_literal: multiple matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select [ @class ]
        \\}
        ,
        .source =
        \\class A {}
        \\class B {}
        ,
        .snapshot_path = "src/tests/snapshots/select_array_multi.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
