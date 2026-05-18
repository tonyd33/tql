const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "basic");

test "simple SELECT variable" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  select @result
        \\}
        ,
        .source = "class Foo {}",
        .name = "select_simple",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with node selector" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class
        \\  select @class
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\function foo() {}
        ,
        .name = "from_node_selector",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with field access" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  select @n
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .name = "from_field_access",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with child navigation" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_body as @body,
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
        .name = "from_child_navigation",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with decorator and WHERE - matching test.tql pattern" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @class,
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
        .name = "from_decorator_with_where",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
