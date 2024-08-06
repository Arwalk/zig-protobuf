const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const tests = @import("../../generated/tests.pb.zig");
const RepeatedEnum = tests.RepeatedEnum;
const TopLevelEnum = tests.TopLevelEnum;

pub fn get(allocator: Allocator) !RepeatedEnum {
    var enum_array = ArrayList(TopLevelEnum).init(allocator);
    try enum_array.append(.SE_ZERO);
    try enum_array.append(.SE2_ZERO);

    return RepeatedEnum{ .value = enum_array };
}
