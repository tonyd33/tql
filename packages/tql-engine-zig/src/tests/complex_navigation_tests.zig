const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "complex_navigation");

test "nested field access" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @c,
        \\       (@c.body > method_definition).name as @nested_name
        \\  select @nested_name
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\}
        ,
        .name = "nested_field_access",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "field access on node selector" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration.name as @name
        \\  select @name
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .name = "field_access_on_node_selector",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "child navigation with field access parent" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @c,
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
        .name = "child_nav_field_access_parent",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "child navigation on node selector" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration.body > method_definition as @method
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
        .name = "child_nav_node_selector",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "descendant navigation with field access parent" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @c,
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
        .name = "descendant_nav_field_access_parent",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "descendant navigation on node selector" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration >> property_identifier as @id
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
        .name = "descendant_nav_node_selector",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "nested child navigation" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @c,
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
        .name = "nested_child_nav",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
