const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

const SnapshotTest = snapshot.SnapshotTester(testing.allocator, "regex");

test "WHERE with regex match - simple pattern" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /Service/
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
        .name = "regex_match_simple",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex match - anchored pattern" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /^Service$/
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
        .name = "regex_match_anchored",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex not match" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n !~ /Service/
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class ServiceProvider {}
        ,
        .name = "regex_not_match",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex match - character class" {
    try (SnapshotTest{
        .tql =
        \\query main() {
        \\  from class_declaration as @c,
        \\       @c.name as @n
        \\  where @n ~ /[A-Z][a-z]+/
        \\  select @c
        \\}
        ,
        .source =
        \\class Service {}
        \\class Controller {}
        \\class foo {}
        ,
        .name = "regex_match_char_class",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
