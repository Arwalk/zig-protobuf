const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

test "leak in allocated string" {
    var demo = longName.WouldYouParseThisForMePlease.init(testing.allocator);
    defer demo.deinit();

    // allocate a "dynamic" string
    const allocated = try testing.allocator.dupe(u8, "asd");
    // copy the allocated string
    demo.field = .{ .field = try protobuf.ManagedString.copy(allocated, testing.allocator) };
    // release the allocated string immediately
    testing.allocator.free(allocated);

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, "asd", demo.field.?.field.getSlice());
}
