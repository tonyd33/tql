const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false;

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "object_literal");

test "select object_literal: shorthand" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select { @class }
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_object_shorthand",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: two shorthand fields" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class,
        \\       @class.name as @name
        \\  select { @class, @name }
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_object_two_shorthand",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: key_value" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select { kind: 'class', node: @class }
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_object_key_value",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "select object_literal: multiple matches" {
    try (SnapshotTest{
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
        .name = "select_object_shorthand_multi",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
