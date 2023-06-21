const std = @import("std");
const protobuf = @import("protobuf");
const mem = std.mem;
const Allocator = mem.Allocator;
const eql = mem.eql;
const fd = protobuf.fd;
const pb_decode = protobuf.pb_decode;
const pb_encode = protobuf.pb_encode;
const pb_deinit = protobuf.pb_deinit;
const pb_init = protobuf.pb_init;
const testing = std.testing;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const FieldType = protobuf.FieldType;
const tests = @import("./generated/tests.pb.zig");
const DefaultValues = @import("./generated/jspb/test.pb.zig").DefaultValues;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "basic encoding" {
    var demo = tests.Demo1{ .a = 150 };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained);

    demo.a = 0;
    const obtained2 = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    try testing.expectEqualSlices(u8, &[_]u8{}, obtained2);
}

test "basic decoding" {
    const input = [_]u8{ 0x08, 0x96, 0x01 };
    const obtained = try tests.Demo1.decode(&input, testing.allocator);

    try testing.expectEqual(tests.Demo1{ .a = 150 }, obtained);

    const input2 = [_]u8{ 0x08, 0x00 };
    const obtained2 = try tests.Demo1.decode(&input2, testing.allocator);
    try testing.expectEqual(tests.Demo1{ .a = 0 }, obtained2);
}

test "basic encoding with optionals" {
    const demo = tests.Demo2{ .a = 150, .b = 0 };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained);

    const demo2 = tests.Demo2{ .a = 150, .b = 150 };
    const obtained2 = try demo2.encode(testing.allocator);
    defer testing.allocator.free(obtained2);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01, 0x10, 0x96, 0x01 }, obtained2);
}

test "basic encoding with negative numbers" {
    var demo = tests.WithNegativeIntegers{ .a = -2, .b = -1 };
    const obtained = try demo.encode(testing.allocator);
    defer demo.deinit();
    defer testing.allocator.free(obtained);
    // 0x08
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x03, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, obtained);
    const decoded = try tests.WithNegativeIntegers.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

test "DemoWithAllVarint" {
    var demo = tests.DemoWithAllVarint{ .sint32 = -1, .sint64 = -1, .uint32 = 150, .uint64 = 150, .a_bool = true, .a_enum = tests.DemoWithAllVarint.DemoEnum.AndAnother, .pos_int32 = 1, .pos_int64 = 2, .neg_int32 = -1, .neg_int64 = -2 };
    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);
    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01, 0x30, 0x02, 0x38, 0x01, 0x40, 0x02, 0x48, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x50, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }, obtained);

    const decoded = try tests.DemoWithAllVarint.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

test "WithSubmessages" {
    var demo = tests.WithSubmessages2{ .sub_demo1 = .{ .a = 1 }, .sub_demo2 = .{ .a = 2, .b = 3 } };

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08 + 2, 0x02, 0x08, 0x01, 0x10 + 2, 0x04, 0x08, 0x02, 0x10, 0x03 }, obtained);

    const decoded = try tests.WithSubmessages2.decode(obtained, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

test "FixedInt - not packed" {
    var demo = tests.WithIntsNotPacked.init(testing.allocator);
    try demo.list_of_data.append(0x08);
    try demo.list_of_data.append(0x01);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08, 0x08,
        0x08, 0x01,
    }, obtained);

    const decoded = try tests.WithIntsNotPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "varint packed - decode empty" {
    const decoded = try tests.WithIntsPacked.decode("\x0A\x00", testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{}, decoded.list_of_data.items);
}

test "varint packed - decode" {
    const decoded = try tests.WithIntsPacked.decode("\x0A\x02\x31\x32", testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 0x31, 0x32 }, decoded.list_of_data.items);
}

test "varint packed - encode, single element multi-byte-varint" {
    var demo = tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0xA3);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0xA3, 0x01 }, obtained);
}

test "varint packed - decode, single element multi-byte-varint" {
    const obtained = &[_]u8{ 0x0A, 0x02, 0xA3, 0x01 };

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{0xA3}, decoded.list_of_data.items);
}

test "varint packed - encode decode, single element single-byte-varint" {
    var demo = tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0x13);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x01, 0x13 }, obtained);

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "varint packed - encode decode - single-byte-varint" {
    var demo = tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0x11);
    try demo.list_of_data.append(0x12);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0x11, 0x12 }, obtained);

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "varint packed - encode - multi-byte-varint" {
    var demo = tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0xA1);
    try demo.list_of_data.append(0xA2);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 }, obtained);
}

test "integration varint packed - decode - multi-byte-varint" {
    const obtained = &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 };

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 }, obtained);

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 0xA1, 0xA2 }, decoded.list_of_data.items);
}

test "FixedSizesList" {
    var demo = tests.FixedSizesList.init(testing.allocator);
    try demo.fixed32List.append(0x01);
    try demo.fixed32List.append(0x02);
    try demo.fixed32List.append(0x03);
    try demo.fixed32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0D, 0x01, 0x00, 0x00, 0x00, 0x0D, 0x02, 0x00, 0x00, 0x00, 0x0D, 0x03, 0x00, 0x00, 0x00, 0x0D, 0x04, 0x00, 0x00, 0x00,
    }, obtained);

    const decoded = try tests.FixedSizesList.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.fixed32List.items, decoded.fixed32List.items);
}

test "VarintListNotPacked - not packed - encode/decode" {
    var demo = tests.VarintListNotPacked.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08, 0x01,
        0x08, 0x02,
        0x08, 0x03,
        0x08, 0x04,
    }, obtained);

    const decoded = try tests.VarintListNotPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
}

test "VarintListNotPacked - decode not packed" {
    const binary = &[_]u8{
        0x08, 0x01,
        0x08, 0x02,
        0x08, 0x03,
        0x08, 0x04,
    };

    const decoded = try tests.VarintListNotPacked.decode(binary, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "VarintListNotPacked - decode packed" {
    const binary = &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    };

    const decoded = try tests.VarintListNotPacked.decode(binary, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "VarintListPacked - encode/decode" {
    var demo = tests.VarintListPacked.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    }, obtained);

    const decoded = try tests.VarintListPacked.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
}

test "VarintListPacked - decode not packed" {
    const binary = &[_]u8{
        0x08, 0x01,
        0x08, 0x02,
        0x08, 0x03,
        0x08, 0x04,
    };

    const decoded = try tests.VarintListPacked.decode(binary, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "VarintListPacked - decode packed" {
    const binary = &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    };

    const decoded = try tests.VarintListPacked.decode(binary, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "SubMessageList" {
    var demo = tests.SubMessageList.init(testing.allocator);
    try demo.subMessageList.append(.{ .a = 1 });
    try demo.subMessageList.append(.{ .a = 2 });
    try demo.subMessageList.append(.{ .a = 3 });
    try demo.subMessageList.append(.{ .a = 4 });
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0x08, 0x01, 0x0A, 0x02, 0x08, 0x02, 0x0A, 0x02, 0x08, 0x03, 0x0A, 0x02, 0x08, 0x04 }, obtained);

    const decoded = try tests.SubMessageList.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(tests.Demo1, demo.subMessageList.items, decoded.subMessageList.items);
}

test "EmptyLists" {
    var demo = tests.EmptyLists.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x08, 0x02, 0x08, 0x03, 0x08, 0x04 }, obtained);

    const decoded = try tests.EmptyLists.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
    try testing.expectEqualSlices(u32, demo.varuint32Empty.items, decoded.varuint32Empty.items);
}

test "EmptyMessage" {
    var demo = tests.EmptyMessage.init(testing.allocator);
    defer demo.deinit();

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{}, obtained);

    const decoded = try tests.EmptyMessage.decode(obtained, testing.allocator);
    defer decoded.deinit();
    try testing.expectEqual(demo, decoded);
}

test "DefaultValuesInit" {
    var demo = DefaultValues.init(testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}

test "DefaultValuesDecode" {
    var demo = try DefaultValues.decode("", testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}
