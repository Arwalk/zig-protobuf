const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

test "leak in allocated string" {
    var demo: longName.WouldYouParseThisForMePlease = .{};
    defer demo.deinit(std.testing.allocator);

    // allocate a "dynamic" string
    const allocated = try testing.allocator.dupe(u8, "asd");
    // move the allocated string
    demo.field = .{ .field = allocated };

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, std.testing.allocator);

    try testing.expectEqualSlices(u8, "asd", demo.field.?.field);
}

test "leak in list of allocated bytes" {
    var my_bytes: std.ArrayList([]const u8) = try .initCapacity(testing.allocator, 1);
    try my_bytes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "abcdef"));

    var msg: tests.WithRepeatedBytes = .{
        .byte_field = my_bytes,
    };
    defer msg.deinit(std.testing.allocator);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try msg.encode(&w.writer, std.testing.allocator);

    var reader: std.Io.Reader = .fixed(w.written());
    var msg_copy = try tests.WithRepeatedBytes.decode(&reader, testing.allocator);
    msg_copy.deinit(std.testing.allocator);
}
