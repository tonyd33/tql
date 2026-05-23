const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "where");

test "WHERE with simple comparison" {
    try (SnapshotTest{
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
        .name = "where_simple_comparison",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with OR logic" {
    try (SnapshotTest{
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
        .name = "where_or_logic",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with AND logic" {
    try (SnapshotTest{
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
        .name = "where_and_logic",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - matches" {
    try (SnapshotTest{
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
        .name = "where_any_matches",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with any quantifier - no matches" {
    try (SnapshotTest{
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
        .name = "where_any_no_matches",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE any matches second method only" {
    try (SnapshotTest{
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
        .name = "where_any_second_only",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with all quantifier" {
    try (SnapshotTest{
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
        .name = "where_all",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with nested any over two sources" {
    try (SnapshotTest{
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
        .name = "where_nested_any",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access on outer row" {
    try (SnapshotTest{
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
        .name = "where_field_access_top_level",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE optional binding is null" {
    try (SnapshotTest{
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
        .name = "where_null_eq",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE optional binding is not null" {
    try (SnapshotTest{
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
        .name = "where_null_ne",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE expression is null" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from function_declaration as @f
        \\  where @f.return_type is null
        \\  select @f
        \\}
        ,
        .source =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
        .name = "where_is_null",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE expression is not null" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from function_declaration as @f
        \\  where @f.return_type is not null
        \\  select @f
        \\}
        ,
        .source =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
        .name = "where_is_not_null",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access with regex match" {
    try (SnapshotTest{
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
        .name = "where_field_access_regex",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access with not equal" {
    try (SnapshotTest{
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
        .name = "where_field_access_ne",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access in AND" {
    try (SnapshotTest{
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
        .name = "where_field_access_and",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE same field accessed twice" {
    try (SnapshotTest{
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
        .name = "where_field_access_twice",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE quantified regression for double yield" {
    try (SnapshotTest{
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
        .name = "where_quantified_double_yield",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE descendant nav in quantifier source" {
    try (SnapshotTest{
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
        .name = "where_descendant_nav_source",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE child nav in comparison body" {
    try (SnapshotTest{
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
        .name = "where_child_nav_in_body",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE field access in OR with anonymous lift" {
    try (SnapshotTest{
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
        .name = "where_field_access_or_quantified",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE any with not-null body" {
    try (SnapshotTest{
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
        .name = "where_any_not_null",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
