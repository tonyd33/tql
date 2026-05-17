const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

test "select object_literal: shorthand" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select { @class }
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/tests/snapshots/select_object_shorthand.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: two shorthand fields" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  select { @class, @name }
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/tests/snapshots/select_object_two_shorthand.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: key_value" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select { kind: 'class', node: @class }
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/tests/snapshots/select_object_key_value.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: multiple matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select { @class }
        \\}
        ,
        .source =
        \\class A {}
        \\class B {}
        \\class C {}
        ,
        .snapshot_path = "src/tests/snapshots/select_object_shorthand_multi.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
