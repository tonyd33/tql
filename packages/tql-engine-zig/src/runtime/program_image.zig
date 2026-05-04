const std = @import("std");
const Allocator = std.mem.Allocator;

const runtime = @import("../runtime.zig");
const Instruction = runtime.Instruction;

const pcre2 = @import("../pcre2.zig");

pub const ProgramImage = struct {
    instructions: []const Instruction,
    regexes: []pcre2.Regex,
    strings: []const []const u8,
    // IMPROVE: array of entry (variable id, string index)
    variable_map: std.hash_map.AutoHashMap(runtime.VariableId, []const u8),

    allocator: Allocator,

    pub fn deinit(self: *ProgramImage) void {
        self.variable_map.deinit();
        self.allocator.free(self.instructions);
        for (self.regexes) |*regex| {
            regex.deinit();
        }
        self.allocator.free(self.regexes);
        for (self.strings) |str| {
            self.allocator.free(str);
        }
        self.allocator.free(self.strings);
    }
};
