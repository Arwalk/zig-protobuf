const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const MoreBytes = @import("../../generated/unittest.pb.zig").MoreBytes;

pub fn get(allocator: Allocator) !MoreBytes {
    var instance: MoreBytes = .{};
    try instance.data.append(allocator, try allocator.dupe(u8, "this will be encoded"));
    try instance.data.append(allocator, try allocator.dupe(u8, "this will also be encoded"));
    try instance.data.append(allocator, try allocator.dupe(u8, "this one as well"));

    return instance;
}
