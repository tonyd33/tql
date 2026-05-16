const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

test "simple SELECT variable" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  select @result
        \\}
        ,
        .source = "class Foo {}",
        .snapshot_path = "src/compiler/tests/snapshots/select_simple.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with node selector" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/compiler/tests/snapshots/from_node_selector.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with field access" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/compiler/tests/snapshots/from_field_access.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with child navigation" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/compiler/tests/snapshots/from_child_navigation.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "FROM with decorator and WHERE - matching test.tql pattern" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/compiler/tests/snapshots/from_decorator_with_where.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
