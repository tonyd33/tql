const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

test "WHERE with simple comparison" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n = 'Service'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_simple_comparison.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with OR logic" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n = 'Service' or @n = 'Controller'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_or_logic.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with AND logic" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @class_name,
        \\       @c.body as @body,
        \\       @body > method_definition as @method_def,
        \\       @method_def.name as @method_name
        \\  where @class_name = 'Service' and @method_name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { foo() {}; bar() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_and_logic.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m != null
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Empty {}
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_any_matches.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - no matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m = null
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_any_no_matches.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with all quantifier" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where all @m in @c.body > method_definition: @m != null
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() {}; bar() {}; }
        \\class B {}
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_all.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with nested any" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition:
        \\          any @n in @c.body > method_definition: @n != null
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_nested_any.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE optional binding is null" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from function_declaration as @f,
        \\       @f.return_type as @rt?
        \\  where @rt = null
        \\  select @f
        \\}
        ,
        .source =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_null_eq.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE optional binding is not null" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from function_declaration as @f,
        \\       @f.return_type as @rt?
        \\  where @rt != null
        \\  select @f
        \\}
        ,
        .source =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_null_ne.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE any with not-null body" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m != null
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_any_not_null.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
