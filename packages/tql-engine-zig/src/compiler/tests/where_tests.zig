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

test "WHERE with exists quantifier - matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.body as @body,
        \\       @body > method_definition as @m,
        \\       @m.name as @method_name
        \\  where exists @m: @method_name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_exists_matches.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with exists quantifier - no matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.body as @body,
        \\       @body > method_definition as @m,
        \\       @m.name as @method_name
        \\  where exists @m: @method_name = 'nonexistent'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_exists_no_matches.snapshot",
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

test "WHERE exists with null inequality body" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.body as @body,
        \\       @body > method_definition as @m,
        \\       @m.return_type as @rt?
        \\  where exists @m: @rt != null
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo(): number { return 1; }; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/compiler/tests/snapshots/where_exists_null_ne.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
