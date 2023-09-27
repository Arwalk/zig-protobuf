const std = @import("std");
const protobuf = @import("protobuf");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");

test "decode empty oneof must be null" {
    const decoded = try tests_oneof.OneofContainer.decode("", testing.allocator);
    defer decoded.deinit();

    try testing.expect(decoded.regular_field.isEmpty());
    try testing.expectEqual(decoded.enum_field, .UNSPECIFIED);
    try testing.expectEqual(decoded.some_oneof, null);
}

test "oneof encode/decode int" {
    var demo = tests_oneof.OneofContainer.init(testing.allocator);
    defer demo.deinit();

    demo.some_oneof = .{ .a_number = 10 };

    {
        // duplicate the one-of and deep compare
        const dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit();
        try testing.expectEqualDeep(demo, dupe);
    }

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x18, 10,
    }, obtained);

    const decoded = try tests_oneof.OneofContainer.decode(obtained, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqual(demo.some_oneof.?.a_number, decoded.some_oneof.?.a_number);
}

test "oneof encode/decode enum" {
    var demo = tests_oneof.OneofContainer.init(testing.allocator);
    defer demo.deinit();

    demo.some_oneof = .{ .enum_value = .SOMETHING2 };

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    {
        // duplicate the one-of and deep compare
        const dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit();
        try testing.expectEqualDeep(demo, dupe);
    }

    try testing.expectEqualSlices(u8, &[_]u8{
        0x30, 0x02,
    }, obtained);

    const decoded = try tests_oneof.OneofContainer.decode(obtained, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqual(demo.some_oneof.?.enum_value, decoded.some_oneof.?.enum_value);
}

test "oneof encode/decode string" {
    var demo = tests_oneof.OneofContainer.init(testing.allocator);
    defer demo.deinit();

    demo.some_oneof = .{ .string_in_oneof = protobuf.ManagedString.static("123") };

    {
        // duplicate the one-of and deep compare
        const dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit();
        try testing.expectEqualDeep(demo, dupe);
    }

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0A, 0x03, 0x31, 0x32, 0x33,
    }, obtained);

    const decoded = try tests_oneof.OneofContainer.decode(obtained, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, demo.some_oneof.?.string_in_oneof.getSlice(), decoded.some_oneof.?.string_in_oneof.getSlice());
}

test "oneof encode/decode submessage" {
    var demo = tests_oneof.OneofContainer.init(testing.allocator);
    defer demo.deinit();

    demo.some_oneof = .{ .message_in_oneof = .{ .value = 1, .str = protobuf.ManagedString.static("123") } };

    {
        // duplicate the one-of and deep compare
        const dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit();
        try testing.expectEqualDeep(demo, dupe);
    }

    const obtained = try demo.encode(testing.allocator);
    defer testing.allocator.free(obtained);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x12, 0x07, 0x08, 0x01, 0x12, 0x03, 0x31, 0x32, 0x33,
    }, obtained);

    const decoded = try tests_oneof.OneofContainer.decode(obtained, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, demo.some_oneof.?.message_in_oneof.str.getSlice(), decoded.some_oneof.?.message_in_oneof.str.getSlice());
}

test "decoding multiple messages keeps the last value 123" {
    const payload = &[_]u8{
        // 1 some_oneof.?.enum_value
        0x30, 0x02,
        // 2 some_oneof.?.string_in_oneof
        0x0A, 0x03,
        0x31, 0x32,
        0x33,
        // 3 demo.some_oneof.?.message_in_oneof
        0x12,
        0x07, 0x08,
        0x01, 0x12,
        0x03, 0x31,
        0x32, 0x33,
    };

    const decoded = try tests_oneof.OneofContainer.decode(payload, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, "123", decoded.some_oneof.?.message_in_oneof.str.getSlice());
}

test "decoding multiple messages keeps the last value 132" {
    // this test also ensures that if multiple values are read during decode, previous values are successfuly
    // freed from memory preventing leaks

    const payload = &[_]u8{
        // 1 some_oneof.?.enum_value
        0x30, 0x02,

        // 3 demo.some_oneof.?.message_in_oneof
        0x12, 0x07,
        0x08, 0x01,
        0x12, 0x03,
        0x31, 0x32,
        0x33,

        // 2 some_oneof.?.string_in_oneof
        0x0A,
        0x03, 0x31,
        0x32, 0x33,
    };

    const decoded = try tests_oneof.OneofContainer.decode(payload, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqualSlices(u8, "123", decoded.some_oneof.?.string_in_oneof.getSlice());
}
