const std = @import("std");

const tests = @import("../../generated/tests.pb.zig");
const WithStrings = tests.WithStrings;

pub fn get(allocator: std.mem.Allocator) !WithStrings {
    return WithStrings{ .name = try allocator.dupe(u8, "test_string") };
}
