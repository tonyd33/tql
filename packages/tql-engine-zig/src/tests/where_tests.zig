const Snapshotter = @import("snapshotter.zig");

test "WHERE with simple comparison" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     @c.name as @n
        \\where @n = 'Service'
        \\select @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "WHERE with OR logic" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     @c.name as @n
        \\where @n = 'Service' or @n = 'Controller'
        \\select @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE with AND logic" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c,
        \\     @c.name as @class_name,
        \\     @c.body as @body,
        \\     @body > method_definition as @method_def,
        \\     @method_def.name as @method_name
        \\where @class_name = 'Service' and @method_name = 'foo'
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { foo() {}; bar() {}; }
        ,
    });
}

test "WHERE with any quantifier - matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m.name = 'foo'
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}

test "WHERE with any quantifier - no matches" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m.name = 'nonexistent'
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}

test "WHERE any matches second method only" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m.name = 'foo'
        \\select @c
        ,
        .target =
        \\class A { bar() {}; foo() {}; }
        \\class B { bar() {}; baz() {}; }
        ,
    });
}

test "WHERE with all quantifier" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where all @m in @c.body > method_definition: @m.name = 'foo'
        \\select @c
        ,
        .target =
        \\class A { foo() {}; foo() {}; }
        \\class B { foo() {}; bar() {}; }
        ,
    });
}

test "WHERE with nested any over two sources" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @a in @c.body > method_definition:
        \\        any @b in @c.body > method_definition: @a.name = @b.name
        \\select @c
        ,
        .target =
        \\class A { foo() {}; }
        ,
    });
}

test "WHERE field access on outer row" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where @c.name = 'Service'
        \\select @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        ,
    });
}

test "WHERE optional binding is null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > function_declaration as @f,
        \\     @f.return_type as @rt?
        \\where @rt = null
        \\select @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE optional binding is not null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > function_declaration as @f,
        \\     @f.return_type as @rt?
        \\where @rt != null
        \\select @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE expression is null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > function_declaration as @f
        \\where @f.return_type is null
        \\select @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE expression is not null" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > function_declaration as @f
        \\where @f.return_type is not null
        \\select @f
        ,
        .target =
        \\function a(): number { return 1; }
        \\function b() { return 2; }
        \\function c(): string { return 'x'; }
        ,
    });
}

test "WHERE field access with regex match" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m.name ~ /^foo.*/
        \\select @c
        ,
        .target =
        \\class A { foobar() {}; }
        \\class B { bar() {}; }
        ,
    });
}

test "WHERE field access with not equal" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where @c.name != 'Service'
        \\select @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE field access in AND" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where @c.name = 'Service' and any @m in @c.body > method_definition: @m.name = 'foo'
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; }
        \\class Service { bar() {}; }
        \\class Other { foo() {}; }
        ,
    });
}

test "WHERE same field accessed twice" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where @c.name = 'Service' or @c.name = 'Controller'
        \\select @c
        ,
        .target =
        \\class Service {}
        \\class Controller {}
        \\class Repository {}
        ,
    });
}

test "WHERE quantified regression for double yield" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @class_decl,
        \\     @class_decl.name as @class_name
        \\where @class_name ~ /Foo.*/ and
        \\      any @md in @class_decl.body > method_definition:
        \\        @md.return_type != null
        \\select { @class_name }
        ,
        .target =
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
    });
}

test "WHERE descendant nav in quantifier source" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c >> method_definition: @m.name = 'foo'
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; }
        \\class Controller { bar() {}; }
        ,
    });
}

test "WHERE child nav in comparison body" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: (@m.body > return_statement) != null
        \\select @c
        ,
        .target =
        \\class A { foo() { return 1; } }
        \\class B { bar() {} }
        ,
    });
}

test "WHERE field access in OR with anonymous lift" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m.name = 'foo' or @m.name = 'bar'
        \\select @c
        ,
        .target =
        \\class A { foo() {}; }
        \\class B { bar() {}; }
        \\class C { baz() {}; }
        ,
    });
}

test "WHERE any with not-null body" {
    try Snapshotter.snapshotQuery(@src(), .{
        .query =
        \\with @root > class_declaration as @c
        \\where any @m in @c.body > method_definition: @m != null
        \\select @c
        ,
        .target =
        \\class Service { foo() {}; bar() {}; }
        \\class Controller { baz() {}; }
        ,
    });
}
