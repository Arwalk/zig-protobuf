const std = @import("std");
const tests = @import("./.generated/generated_in_ci.pb.zig");
const testing = std.testing;

test "Varints" {
    var demo = try tests.Varints.init(testing.allocator);
    defer demo.deinit(std.testing.allocator);
    demo.sint32 = -1;
    demo.sint64 = -1;
    demo.uint32 = 150;
    demo.uint64 = 150;
    demo.a_bool = true;

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x10, 0x01, 0x18, 0x96, 0x01, 0x20, 0x96, 0x01, 0x28, 0x01 }, obtained.items);

    const decoded = try tests.Varints.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqual(demo, decoded);
}

// Extracted from the documentation site
// https://protobuf.dev/programming-guides/encoding/
test "optional and repeated elements" {
    const decoded = try tests.TestOptional.decode("\x22\x05\x68\x65\x6c\x6c\x6f\x28\x01\x28\x02\x28\x03", testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, decoded.e.items);
    try testing.expectEqualSlices(u8, "hello", decoded.d.?);
}

test "packed example from protobuf documentation" {
    const bytes = "\x32\x06\x03\x8e\x02\x9e\xa7\x05";
    const m = try tests.TestPacked.decode(bytes, testing.allocator);
    defer m.deinit(std.testing.allocator);
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 270, 86942 }, m.f.items);
}

test "packed example from protobuf documentation repeated" {
    const bytes = "\x32\x06\x03\x8e\x02\x9e\xa7\x05\x32\x06\x03\x8e\x02\x9e\xa7\x05";
    const m = try tests.TestPacked.decode(bytes, testing.allocator);
    defer m.deinit(std.testing.allocator);
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 270, 86942, 3, 270, 86942 }, m.f.items);
}

test "Varints - encode/decode equivalence" {
    var demo = try tests.Varints.init(testing.allocator);
    defer demo.deinit(std.testing.allocator);
    demo.sint32 = -105;
    demo.sint64 = -11119487612;
    demo.uint32 = 923658273;
    demo.uint64 = 1512312313130;
    demo.a_bool = true;

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    const decoded = try tests.Varints.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualDeep(demo, decoded);
}

test "EmptyLists" {
    var demo = try tests.EmptyLists.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01, 0x08, 0x02, 0x08, 0x03, 0x08, 0x04 }, obtained.items);

    const decoded = try tests.EmptyLists.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, demo.varuint32List.items, decoded.varuint32List.items);
    try testing.expectEqualSlices(u32, demo.varuint32Empty.items, decoded.varuint32Empty.items);
}

test "SubMessageList" {
    var demo = try tests.SubMessageList.init(testing.allocator);
    try demo.subMessageList.append(.{ .a = 1 });
    try demo.subMessageList.append(.{ .a = 2 });
    try demo.subMessageList.append(.{ .a = 3 });
    try demo.subMessageList.append(.{ .a = 4 });
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x0A, 0x02, 0x08, 0x01, 0x0A, 0x02, 0x08, 0x02, 0x0A, 0x02, 0x08, 0x03, 0x0A, 0x02, 0x08, 0x04 },
        obtained.items,
    );

    const decoded = try tests.SubMessageList.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(tests.Demo1, demo.subMessageList.items, decoded.subMessageList.items);
}

test "VarintListPacked - encode/decode" {
    var demo = try tests.VarintListPacked.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    }, obtained.items);

    const decoded = try tests.VarintListPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
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
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "VarintListPacked - decode packed" {
    const binary = &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    };

    const decoded = try tests.VarintListPacked.decode(binary, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "basic encoding" {
    var demo = tests.Demo1{ .a = 150 };

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained.items);

    demo.a = 0;
    var obtained2: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained2.deinit(std.testing.allocator);

    const w2 = obtained2.writer(std.testing.allocator);
    try demo.encode(w2.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{}, obtained2.items);
}

test "EmptyMessage" {
    var demo = try tests.EmptyMessage.init(testing.allocator);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{}, obtained.items);

    const decoded = try tests.EmptyMessage.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqual(demo, decoded);
}

test "integration varint packed - decode - multi-byte-varint" {
    const obtained = &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 };

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 }, obtained);

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 0xA1, 0xA2 }, decoded.list_of_data.items);
}

test "FixedSizesList" {
    var demo = try tests.FixedSizesList.init(testing.allocator);
    try demo.fixed32List.append(0x01);
    try demo.fixed32List.append(0x02);
    try demo.fixed32List.append(0x03);
    try demo.fixed32List.append(0x04);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0D, 0x01, 0x00, 0x00, 0x00, 0x0D, 0x02, 0x00, 0x00, 0x00, 0x0D, 0x03, 0x00, 0x00, 0x00, 0x0D, 0x04, 0x00, 0x00, 0x00,
    }, obtained.items);

    const decoded = try tests.FixedSizesList.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, demo.fixed32List.items, decoded.fixed32List.items);
}

test "VarintListNotPacked - not packed - encode/decode" {
    var demo = try tests.VarintListNotPacked.init(testing.allocator);
    try demo.varuint32List.append(0x01);
    try demo.varuint32List.append(0x02);
    try demo.varuint32List.append(0x03);
    try demo.varuint32List.append(0x04);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08, 0x01,
        0x08, 0x02,
        0x08, 0x03,
        0x08, 0x04,
    }, obtained.items);

    const decoded = try tests.VarintListNotPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
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
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "VarintListNotPacked - decode packed" {
    const binary = &[_]u8{
        0x0A, 0x04,
        0x01, 0x02,
        0x03, 0x04,
    };

    const decoded = try tests.VarintListNotPacked.decode(binary, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, decoded.varuint32List.items);
}

test "varint packed - decode empty" {
    const decoded = try tests.WithIntsPacked.decode("\x0A\x00", testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{}, decoded.list_of_data.items);
}

test "varint packed - decode" {
    const decoded = try tests.WithIntsPacked.decode("\x0A\x02\x31\x32", testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{ 0x31, 0x32 }, decoded.list_of_data.items);
}

test "varint packed - encode, single element multi-byte-varint" {
    var demo = try tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0xA3);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0xA3, 0x01 }, obtained.items);
}

test "varint packed - decode, single element multi-byte-varint" {
    const obtained = &[_]u8{ 0x0A, 0x02, 0xA3, 0x01 };

    const decoded = try tests.WithIntsPacked.decode(obtained, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, &[_]u32{0xA3}, decoded.list_of_data.items);
}

test "varint packed - encode decode, single element single-byte-varint" {
    var demo = try tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0x13);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x01, 0x13 }, obtained.items);

    const decoded = try tests.WithIntsPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "varint packed - encode decode - single-byte-varint" {
    var demo = try tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0x11);
    try demo.list_of_data.append(0x12);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x02, 0x11, 0x12 }, obtained.items);

    const decoded = try tests.WithIntsPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "varint packed - encode - multi-byte-varint" {
    var demo = try tests.WithIntsPacked.init(testing.allocator);
    try demo.list_of_data.append(0xA1);
    try demo.list_of_data.append(0xA2);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x04, 0xA1, 0x01, 0xA2, 0x01 }, obtained.items);
}

test "WithSubmessages" {
    var demo = tests.WithSubmessages2{ .sub_demo1 = .{ .a = 1 }, .sub_demo2 = .{ .a = 2, .b = 3 } };

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x08 + 2, 0x02, 0x08, 0x01, 0x10 + 2, 0x04, 0x08, 0x02, 0x10, 0x03 }, obtained.items);

    const decoded = try tests.WithSubmessages2.decode(obtained.items, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

test "FixedInt - not packed" {
    var demo = try tests.WithIntsNotPacked.init(testing.allocator);
    try demo.list_of_data.append(0x08);
    try demo.list_of_data.append(0x01);
    defer demo.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x08, 0x08,
        0x08, 0x01,
    }, obtained.items);

    const decoded = try tests.WithIntsNotPacked.decode(obtained.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try testing.expectEqualSlices(u32, demo.list_of_data.items, decoded.list_of_data.items);
}

test "basic encoding with optionals" {
    const demo = tests.Demo2{ .a = 150, .b = 0 };

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, obtained.items);

    const demo2 = tests.Demo2{ .a = 150, .b = 150 };

    var obtained2: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained2.deinit(std.testing.allocator);

    const w2 = obtained2.writer(std.testing.allocator);
    try demo2.encode(w2.any(), std.testing.allocator);

    // 0x08 , 0x96, 0x01
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01, 0x10, 0x96, 0x01 }, obtained2.items);
}

test "basic decoding" {
    const input = [_]u8{ 0x08, 0x96, 0x01 };
    const obtained = try tests.Demo1.decode(&input, testing.allocator);

    try testing.expectEqual(tests.Demo1{ .a = 150 }, obtained);

    const input2 = [_]u8{ 0x08, 0x00 };
    const obtained2 = try tests.Demo1.decode(&input2, testing.allocator);
    try testing.expectEqual(tests.Demo1{ .a = 0 }, obtained2);
}

test "DemoWithAllVarint" {
    const demo = tests.DemoWithAllVarint{ .sint32 = -1, .sint64 = -1, .uint32 = 150, .uint64 = 150, .a_bool = true, .a_enum = tests.DemoWithAllVarint.DemoEnum.AndAnother, .pos_int32 = 1, .pos_int64 = 2, .neg_int32 = -1, .neg_int64 = -2 };
    try check(demo, "08011001189601209601280130023801400248ffffffffffffffffff0150feffffffffffffffff01");
}

test "basic encoding with negative numbers" {
    var demo = tests.WithNegativeIntegers{ .a = -2, .b = -1 };

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try demo.encode(w.any(), std.testing.allocator);

    // 0x08
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x08, 0x03, 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 },
        obtained.items,
    );
    const decoded = try tests.WithNegativeIntegers.decode(obtained.items, testing.allocator);
    try testing.expectEqual(demo, decoded);
}

fn check(object: anytype, expected: []const u8) !void {
    defer object.deinit(std.testing.allocator);

    var obtained: std.ArrayListUnmanaged(u8) = .empty;
    defer obtained.deinit(std.testing.allocator);

    const w = obtained.writer(std.testing.allocator);
    try object.encode(w.any(), std.testing.allocator);

    const buffer = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(buffer);
    const bytes = try std.fmt.hexToBytes(buffer, expected);

    try testing.expectEqualSlices(u8, bytes, obtained.items);
    const decoded = try @TypeOf(object).decode(obtained.items, testing.allocator);
    try testing.expectEqual(object, decoded);
}

test "sint32, sint64, uint32, uint64 all to 1" {
    const demo = tests.DemoWithAllVarint{ .sint32 = 1, .sint64 = 1, .uint32 = 1, .uint64 = 1 };
    try check(demo, "0802100218012001");
}

test "sint32, sint64 to -1" {
    const demo = tests.DemoWithAllVarint{ .sint32 = -1, .sint64 = -1 };
    try check(demo, "08011001");
}

test "sint32, sint64, uint32, uint64 to their max value" {
    const demo = tests.DemoWithAllVarint{ .sint32 = std.math.maxInt(i32), .sint64 = std.math.maxInt(i64), .uint32 = std.math.maxInt(u32), .uint64 = std.math.maxInt(u64) };
    try check(demo, "08feffffff0f10feffffffffffffffff0118ffffffff0f20ffffffffffffffffff01");
}

test "sint32, sint64 to their min value" {
    const demo = tests.DemoWithAllVarint{ .sint32 = std.math.minInt(i32), .sint64 = std.math.minInt(i64) };
    try check(demo, "08ffffffff0f10ffffffffffffffffff01");
}

test "int32, int64 to their low boundaries (-1, 1)" {
    const demo = tests.DemoWithAllVarint{
        .pos_int32 = 1,
        .pos_int64 = 1,
        .neg_int32 = -1,
        .neg_int64 = -1,
    };
    try check(demo, "3801400148ffffffffffffffffff0150ffffffffffffffffff01");
}

test "int32, int64 to their high boundaries (maxneg, maxpos)" {
    const demo = tests.DemoWithAllVarint{
        .pos_int32 = 0x7FFFFFFF,
        .pos_int64 = 0x7FFFFFFFFFFFFFFF,
        .neg_int32 = -2147483648,
        .neg_int64 = -9223372036854775808,
    };
    try check(demo, "38ffffffff0740ffffffffffffffff7f4880808080f8ffffffff015080808080808080808001");
}
