const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "basic");

test "FROM with node selector" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @class
        \\  select @class
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\function foo() {}
        ,
        .name = "with_node_selector",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with field access" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @c,
        \\       @c.name as @n
        \\  select @n
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .name = "with_field_access",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with child navigation" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration > class_body as @body,
        \\       @body > method_definition as @m
        \\  select @m
        \\}
        ,
        .source =
        \\class Service {
        \\  foo() {}
        \\  bar() {}
        \\}
        ,
        .name = "with_child_navigation",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with decorator and WHERE - matching test.tql pattern" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  with class_declaration as @class,
        \\       @class.name as @class_name,
        \\       @class.decorator as @class_decorator,
        \\       @class_decorator > call_expression as @decorator_call,
        \\       @decorator_call.function as @decorator_name
        \\  where @decorator_name = 'Controller'
        \\  select @decorator_name
        \\}
        ,
        .source =
        \\@Controller()
        \\class Foo {
        \\  m1() { }
        \\  m2() { }
        \\}
        \\
        \\@NotController()
        \\class Bar {
        \\  m1() { }
        \\}
        ,
        .name = "with_decorator_with_where",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
