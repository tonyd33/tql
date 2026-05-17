const std = @import("std");
const testing = std.testing;
const snapshot = @import("./snapshot_helper.zig");

const UPDATE_SNAPSHOTS = false; // Set to true to update all snapshots

test "WHERE with regex match - simple pattern" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/tests/snapshots/regex_match_simple.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex match - anchored pattern" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/tests/snapshots/regex_match_anchored.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex not match" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/tests/snapshots/regex_not_match.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}

test "WHERE with regex match - character class" {
    try (snapshot.SnapshotTest{
        .allocator = testing.allocator,
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
        .snapshot_path = "src/tests/snapshots/regex_match_char_class.snapshot",
        .update_snapshots = UPDATE_SNAPSHOTS,
    }).run();
}
