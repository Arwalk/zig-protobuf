const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "long name" {
    // - this test allocates an object only. used to instruct zig to try to compile the file
    // - it also ensures that SubMessage deinit() works
    var demo = longName.WouldYouParseThisForMePlease.init(testing.allocator);
    demo.field = .{ .field = "asd" };
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
}

test "packed int32_list encoding" {
    var demo = tests.Packed.init(testing.allocator);
    try demo.int32_list.append(0x01);
    try demo.int32_list.append(0x02);
    try demo.int32_list.append(0x03);
    try demo.int32_list.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        // fieldNumber=1<<3 packetType=2 (LEN)
        (1 << 3) + 2,
        // 4 bytes
        0x04,
        // payload
        0x01,
        0x02,
        0x03,
        0x04,
    }, obtained);

    const decoded = try tests.Packed.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(i32, demo.int32_list.items, decoded.int32_list.items);
}

test "unpacked int32_list" {
    var demo = tests.UnPacked.init(testing.allocator);
    try demo.int32_list.append(0x01);
    try demo.int32_list.append(0x02);
    try demo.int32_list.append(0x03);
    try demo.int32_list.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x08, 0x02, 0x08, 0x03, 0x08, 0x04 }, obtained);

    const decoded = try tests.UnPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(i32, demo.int32_list.items, decoded.int32_list.items);
}

test "Required.Proto3.ProtobufInput.ValidDataRepeated.BOOL.PackedInput.ProtobufOutput" {
    const bytes = "\xda\x02\x28\x00\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01\xce\xc2\xf1\x05\x80\x80\x80\x80\x20\xff\xff\xff\xff\xff\xff\xff\xff\x7f\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01";
    const m = try proto3.TestAllTypesProto3.decode(bytes, testing.allocator);
    defer m.deinit();

    // TODO: try testing.expectEqualSlices(bool, &[_]bool{ false, false, false, false, true, false, false }, m.repeated_bool.items);
}

test "packed example from protobuf documentation" {
    const bytes = "\x32\x06\x03\x8e\x02\x9e\xa7\x05";
    const m = try tests.TestPacked.decode(bytes, testing.allocator);
    defer m.deinit();
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 270, 86942 }, m.f.items);
}

test "packed example from protobuf documentation repeated" {
    const bytes = "\x32\x06\x03\x8e\x02\x9e\xa7\x05\x32\x06\x03\x8e\x02\x9e\xa7\x05";
    const m = try tests.TestPacked.decode(bytes, testing.allocator);
    defer m.deinit();
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 270, 86942, 3, 270, 86942 }, m.f.items);
}
