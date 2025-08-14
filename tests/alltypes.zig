const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const jspb = @import("./generated/jspb/test.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "long package" {
    // - this test allocates an object only. used to instruct zig to try to compile the file
    // - it also ensures that SubMessage deinit() works
    var demo = try longName.WouldYouParseThisForMePlease.init(testing.allocator);
    demo.field = .{ .field = try std.testing.allocator.dupe(u8, "asd") };
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);
    const w = obtained.writer(std.testing.allocator);

    try demo.encode(w.any(), std.testing.allocator);
}

test "packed int32_list encoding" {
    var demo = try tests.Packed.init(std.testing.allocator);
    defer demo.deinit(std.testing.allocator);
    try demo.int32_list.append(std.testing.allocator, 0x01);
    try demo.int32_list.append(std.testing.allocator, 0x02);
    try demo.int32_list.append(std.testing.allocator, 0x03);
    try demo.int32_list.append(std.testing.allocator, 0x04);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);
    const w = obtained.writer(std.testing.allocator);

    try demo.encode(w.any(), std.testing.allocator);

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
    }, obtained.items);

    var decoded = try tests.Packed.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(i32, demo.int32_list.items, decoded.int32_list.items);
}

test "unpacked int32_list" {
    var demo = try tests.UnPacked.init(testing.allocator);
    defer demo.deinit(std.testing.allocator);
    try demo.int32_list.append(std.testing.allocator, 0x01);
    try demo.int32_list.append(std.testing.allocator, 0x02);
    try demo.int32_list.append(std.testing.allocator, 0x03);
    try demo.int32_list.append(std.testing.allocator, 0x04);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);
    const w = obtained.writer(std.testing.allocator);

    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x08, 0x02, 0x08, 0x03, 0x08, 0x04 }, obtained.items);

    var decoded = try tests.UnPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(i32, demo.int32_list.items, decoded.int32_list.items);
}

test "Required.Proto3.ProtobufInput.ValidDataRepeated.BOOL.PackedInput.ProtobufOutput" {
    const bytes = "\xda\x02\x28\x00\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01\xce\xc2\xf1\x05\x80\x80\x80\x80\x20\xff\xff\xff\xff\xff\xff\xff\xff\x7f\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01";
    var m = try proto3.TestAllTypesProto3.decode(bytes, testing.allocator);
    defer m.deinit(std.testing.allocator);

    // TODO: try testing.expectEqualSlices(bool, &[_]bool{ false, false, false, false, true, false, false }, m.repeated_bool.items);
}

test "msg-longs.proto" {
    const bytes = &[_]u8{ 17, 255, 255, 255, 255, 255, 255, 255, 255, 24, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1, 32, 255, 255, 255, 255, 255, 255, 255, 255, 127, 41, 0, 0, 0, 0, 0, 0, 0, 128, 49, 255, 255, 255, 255, 255, 255, 255, 127, 56, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 64, 254, 255, 255, 255, 255, 255, 255, 255, 255, 1, 80, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 97, 255, 255, 255, 255, 255, 255, 255, 255, 104, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1, 112, 255, 255, 255, 255, 255, 255, 255, 255, 127, 121, 0, 0, 0, 0, 0, 0, 0, 128, 129, 1, 255, 255, 255, 255, 255, 255, 255, 127, 136, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 144, 1, 254, 255, 255, 255, 255, 255, 255, 255, 255, 1, 160, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 177, 1, 255, 255, 255, 255, 255, 255, 255, 255, 184, 1, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1, 192, 1, 255, 255, 255, 255, 255, 255, 255, 255, 127, 201, 1, 0, 0, 0, 0, 0, 0, 0, 128, 209, 1, 255, 255, 255, 255, 255, 255, 255, 127, 216, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 224, 1, 254, 255, 255, 255, 255, 255, 255, 255, 255, 1, 240, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 };
    var decoded = try longs.LongsMessage.decode(bytes, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqual(@as(u64, 0), decoded.fixed64_field_min);
    try testing.expectEqual(@as(u64, 18446744073709551615), decoded.fixed64_field_max);
    try testing.expectEqual(@as(i64, -9223372036854775808), decoded.int64_field_min);
    try testing.expectEqual(@as(i64, 9223372036854775807), decoded.int64_field_max);
    try testing.expectEqual(@as(i64, -9223372036854775808), decoded.sfixed64_field_min);
    try testing.expectEqual(@as(i64, 9223372036854775807), decoded.sfixed64_field_max);
    try testing.expectEqual(@as(i64, -9223372036854775808), decoded.sint64_field_min);
    try testing.expectEqual(@as(i64, 9223372036854775807), decoded.sint64_field_max);
    try testing.expectEqual(@as(u64, 0), decoded.uint64_field_min);
    try testing.expectEqual(@as(u64, 18446744073709551615), decoded.uint64_field_max);
}

test "TestExtremeDefaultValues" {
    var decoded = try unittest.TestExtremeDefaultValues.decode("", testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqualSlices(u8, "\\000\\001\\007\\010\\014\\n\\r\\t\\013\\\\\\'\\\"\\376", decoded.escaped_bytes.?);
    try testing.expectEqual(@as(u32, 4294967295), decoded.large_uint32.?);
    try testing.expectEqual(@as(u64, 18446744073709551615), decoded.large_uint64.?);
    try testing.expectEqual(@as(i32, -2147483647), decoded.small_int32.?);
    try testing.expectEqual(@as(i64, -9223372036854775807), decoded.small_int64.?);
    try testing.expectEqual(@as(i32, -2147483648), decoded.really_small_int32.?);
    try testing.expectEqual(@as(i64, -9223372036854775808), decoded.really_small_int64.?);
    try testing.expectEqualSlices(u8, "\xE1\x88\xB4", decoded.utf8_string.?);
    try testing.expectEqual(@as(f32, 0), decoded.zero_float.?);
    try testing.expectEqual(@as(f32, 1), decoded.one_float.?);
    try testing.expectEqual(@as(f32, 1.5), decoded.small_float.?);
    try testing.expectEqual(@as(f32, -1), decoded.negative_one_float.?);
    try testing.expectEqual(@as(f32, -1.5), decoded.negative_float.?);
    try testing.expectEqual(@as(f32, 2e+08), decoded.large_float.?);
    try testing.expectEqual(@as(f32, -8e-28), decoded.small_negative_float.?);
    try testing.expectEqual(@as(f64, std.math.inf(f64)), decoded.inf_double.?);
    try testing.expectEqual(@as(f64, -std.math.inf(f64)), decoded.neg_inf_double.?);
    try testing.expect(std.math.isNan(decoded.nan_double.?));
    try testing.expectEqual(@as(f32, std.math.inf(f32)), decoded.inf_float.?);
    try testing.expectEqual(@as(f32, -std.math.inf(f32)), decoded.neg_inf_float.?);
    try testing.expect(std.math.isNan(decoded.nan_float.?));
    try testing.expectEqualSlices(u8, "? ? ?? ?? ??? ??/ ??-", decoded.cpp_trigraph.?);
    try testing.expectEqualSlices(u8, "hel\x00lo", decoded.string_with_zero.?);
    try testing.expectEqualSlices(u8, "wor\\000ld", decoded.bytes_with_zero.?);
    try testing.expectEqualSlices(u8, "ab\x00c", decoded.string_piece_with_zero.?);
    try testing.expectEqualSlices(u8, "12\x003", decoded.cord_with_zero.?);
    try testing.expectEqualSlices(u8, "${unknown}", decoded.replacement_string.?);
}
