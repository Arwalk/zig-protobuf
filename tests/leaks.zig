const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

test "leak in allocated string" {
    var demo = try longName.WouldYouParseThisForMePlease.init(testing.allocator);
    defer demo.deinit(std.testing.allocator);

    // allocate a "dynamic" string
    const allocated = try testing.allocator.dupe(u8, "asd");
    // copy the allocated string
    demo.field = .{ .field = allocated };

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);
    const w = obtained.writer(std.testing.allocator);

    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, "asd", demo.field.?.field);
}

test "leak in list of allocated bytes" {
    var my_bytes = try std.ArrayListUnmanaged([]const u8).initCapacity(testing.allocator, 1);
    try my_bytes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "abcdef"));

    var msg = tests.WithRepeatedBytes{
        .byte_field = my_bytes,
    };
    defer msg.deinit(std.testing.allocator);

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    const w = buffer.writer(std.testing.allocator);

    try msg.encode(w.any(), std.testing.allocator);

    var fbs = std.io.fixedBufferStream(buffer.items);
    const r = fbs.reader();
    var msg_copy = try tests.WithRepeatedBytes.decode(r.any(), testing.allocator);
    msg_copy.deinit(std.testing.allocator);
}
