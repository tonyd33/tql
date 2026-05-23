const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "array_literal");

test "select array_literal: single variable" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @class
        \\  select [ @class ]
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_array_single",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select array_literal: mixed" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @class
        \\  select [ 'class', @class ]
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_array_mixed",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select array_literal: multiple matches" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @class
        \\  select [ @class ]
        \\}
        ,
        .source =
        \\class A {}
        \\class B {}
        ,
        .name = "select_array_multi",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
