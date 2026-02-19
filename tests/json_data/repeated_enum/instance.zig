const std = @import("std");
const tests = @import("../../generated/tests.pb.zig");
const RepeatedEnum = tests.RepeatedEnum;
const TopLevelEnum = tests.TopLevelEnum;

pub fn get(allocator: std.mem.Allocator) !RepeatedEnum {
    var enum_array: std.ArrayList(TopLevelEnum) = try .initCapacity(allocator, 2);
    try enum_array.append(allocator, .SE_ZERO);
    try enum_array.append(allocator, .SE2_ZERO);

    return RepeatedEnum{ .value = enum_array };
}
