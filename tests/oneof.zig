const std = @import("std");
const protobuf = @import("protobuf");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");

test "decode empty oneof must be null" {
    var reader: std.Io.Reader = .fixed("");
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expect(decoded.regular_field.len == 0);
    try testing.expectEqual(decoded.enum_field, .UNSPECIFIED);
    try testing.expectEqual(decoded.some_oneof, null);
}

test "oneof encode/decode int" {
    var demo: tests_oneof.OneofContainer = .{};
    defer demo.deinit(std.testing.allocator);

    demo.some_oneof = .{ .a_number = 10 };

    {
        // duplicate the one-of and deep compare
        var dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit(std.testing.allocator);
        try testing.expectEqualDeep(demo, dupe);
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x18, 10,
    }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqual(demo.some_oneof.?.a_number, decoded.some_oneof.?.a_number);
}

test "oneof encode/decode enum" {
    var demo: tests_oneof.OneofContainer = .{};
    defer demo.deinit(std.testing.allocator);

    demo.some_oneof = .{ .enum_value = .SOMETHING2 };

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, testing.allocator);

    {
        // duplicate the one-of and deep compare
        var dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit(std.testing.allocator);
        try testing.expectEqualDeep(demo, dupe);
    }

    try testing.expectEqualSlices(u8, &[_]u8{
        0x30, 0x02,
    }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqual(demo.some_oneof.?.enum_value, decoded.some_oneof.?.enum_value);
}

test "oneof encode/decode string" {
    var demo: tests_oneof.OneofContainer = .{};
    defer demo.deinit(std.testing.allocator);

    demo.some_oneof = .{ .string_in_oneof = try std.testing.allocator.dupe(u8, "123") };

    {
        // duplicate the one-of and deep compare
        var dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit(std.testing.allocator);
        try testing.expectEqualDeep(demo, dupe);
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x0A, 0x03, 0x31, 0x32, 0x33,
    }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqualSlices(
        u8,
        demo.some_oneof.?.string_in_oneof,
        decoded.some_oneof.?.string_in_oneof,
    );
}

test "oneof encode/decode submessage" {
    var demo: tests_oneof.OneofContainer = .{};
    defer demo.deinit(std.testing.allocator);

    demo.some_oneof = .{ .message_in_oneof = .{ .value = 1, .str = try std.testing.allocator.dupe(u8, "123") } };

    {
        // duplicate the one-of and deep compare
        var dupe = try demo.dupe(testing.allocator);
        defer dupe.deinit(std.testing.allocator);
        try testing.expectEqualDeep(demo, dupe);
    }

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{
        0x12, 0x07, 0x08, 0x01, 0x12, 0x03, 0x31, 0x32, 0x33,
    }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqualSlices(
        u8,
        demo.some_oneof.?.message_in_oneof.str,
        decoded.some_oneof.?.message_in_oneof.str,
    );
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

    var reader: std.Io.Reader = .fixed(payload);
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqualSlices(u8, "123", decoded.some_oneof.?.message_in_oneof.str);
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

    var reader: std.Io.Reader = .fixed(payload);
    var decoded = try tests_oneof.OneofContainer.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqualSlices(u8, "123", decoded.some_oneof.?.string_in_oneof);
}
