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
        .snapshot_path = "src/tests/snapshots/where_simple_comparison.snapshot",
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
        .snapshot_path = "src/tests/snapshots/where_or_logic.snapshot",
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
        .snapshot_path = "src/tests/snapshots/where_and_logic.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m.name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_any_matches.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - no matches" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m.name = 'nonexistent'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_any_no_matches.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE any matches second method only" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m.name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class A { bar() {}; foo() {}; }
        \\class B { bar() {}; baz() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_any_second_only.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with all quantifier" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where all @m in @c.body > method_definition: @m.name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() {}; foo() {}; }
        \\class B { foo() {}; bar() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_all.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with nested any over two sources" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @a in @c.body > method_definition:
        \\          any @b in @c.body > method_definition: @a.name = @b.name
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_nested_any.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access on outer row" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where @c.name = 'Service'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_top_level.snapshot",
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
        .snapshot_path = "src/tests/snapshots/where_null_eq.snapshot",
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
        .snapshot_path = "src/tests/snapshots/where_null_ne.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access with regex match" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m.name ~ /^foo.*/
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foobar() {}; }
        \\class B { bar() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_regex.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access with not equal" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where @c.name != 'Service'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_ne.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access in AND" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where @c.name = 'Service' and any @m in @c.body > method_definition: @m.name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; }
        \\class Service { bar() {}; }
        \\class Other { foo() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_and.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE same field accessed twice" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where @c.name = 'Service' or @c.name = 'Controller'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_twice.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE quantified regression for double yield" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @class_decl,
        \\       @class_decl.name as @class_name
        \\  where @class_name ~ /Foo.*/ and
        \\        any @md in @class_decl.body > method_definition:
        \\          @md.return_type != null
        \\  select { @class_name }
        \\}
        ,
        .source =
        \\class Foo1 {
        \\  m1(): string {}
        \\  m2() {}
        \\  m3(): number {}
        \\}
        \\
        \\class Foo2 {}
        \\
        \\class Foo3 {
        \\  m3() {}
        \\}
        ,
        .snapshot_path = "src/tests/snapshots/where_quantified_double_yield.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE descendant nav in quantifier source" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c >> method_definition: @m.name = 'foo'
        \\  select @c
        \\}
        ,
        .source =
        \\class Service { foo() {}; }
        \\class Controller { bar() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_descendant_nav_source.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE child nav in comparison body" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: (@m.body > return_statement) != null
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() { return 1; } }
        \\class B { bar() {} }
        ,
        .snapshot_path = "src/tests/snapshots/where_child_nav_in_body.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access in OR with anonymous lift" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
        .tql =
        \\query main() {
        \\  from class_declaration as @c
        \\  where any @m in @c.body > method_definition: @m.name = 'foo' or @m.name = 'bar'
        \\  select @c
        \\}
        ,
        .source =
        \\class A { foo() {}; }
        \\class B { bar() {}; }
        \\class C { baz() {}; }
        ,
        .snapshot_path = "src/tests/snapshots/where_field_access_or_quantified.snapshot",
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
        .snapshot_path = "src/tests/snapshots/where_any_not_null.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
