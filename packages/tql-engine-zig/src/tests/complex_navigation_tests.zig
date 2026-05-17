const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

test "nested field access" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       (@c.body > method_definition).name as @nested_name
        \\  select @nested_name
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/nested_field_access.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "field access on node selector" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration.name as @name
        \\  select @name
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .snapshot_path = "src/tests/snapshots/field_access_on_node_selector.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "child navigation with field access parent" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.body > method_definition as @method
        \\  select @method
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/child_nav_field_access_parent.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "child navigation on node selector" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration.body > method_definition as @method
        \\  select @method
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        \\class Controller {
        \\  baz() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/child_nav_node_selector.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "descendant navigation with field access parent" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.body >> property_identifier as @id
        \\  select @id
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/descendant_nav_field_access_parent.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "descendant navigation on node selector" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration >> property_identifier as @id
        \\  select @id
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\}
        \\class Controller {
        \\  bar() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/descendant_nav_node_selector.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "nested child navigation" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       (@c > class_body) > method_definition as @method
        \\  select @method
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/nested_child_nav.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
