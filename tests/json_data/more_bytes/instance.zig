const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ManagedString = @import("protobuf").ManagedString;
const MoreBytes = @import("../../generated/unittest.pb.zig").MoreBytes;

pub fn get(allocator: Allocator) !MoreBytes {
    var instance = MoreBytes.init(allocator);
    try instance.data.append(ManagedString.static("this will be encoded"));
    try instance.data.append(ManagedString.static("this will also be encoded"));
    try instance.data.append(ManagedString.static("this one as well"));

    return instance;
}
