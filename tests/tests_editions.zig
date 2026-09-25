const std = @import("std");
const testing = std.testing;
const editions = @import("./generated/tests/editions.pb.zig");

fn encode(msg: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    try msg.encode(&w.writer, testing.allocator);
    return w.toOwnedSlice();
}

fn decode(comptime T: type, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return T.decode(&reader, testing.allocator);
}

test "editions: delimited submessage is encoded as a group" {
    const msg: editions.Delimited = .{ .child = .{ .a = 1 } };
    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);

    // SGROUP(1), a = 1, EGROUP(1)
    try testing.expectEqualSlices(u8, &.{ 0x0B, 0x08, 0x01, 0x0C }, bytes);

    var decoded = try decode(editions.Delimited, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(1, decoded.child.?.a);
}

test "editions: repeated and oneof delimited submessages" {
    var msg: editions.Delimited = .{ .choice = .{ .oneof_child = .{ .a = 3 } } };
    defer msg.children.deinit(testing.allocator);
    try msg.children.append(testing.allocator, .{ .a = 1 });
    try msg.children.append(testing.allocator, .{ .a = 2 });

    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x13, 0x08, 0x01, 0x14, // children[0]: SGROUP(2), a = 1, EGROUP(2)
        0x13, 0x08, 0x02, 0x14, // children[1]
        0x23, 0x08, 0x03, 0x24, // oneof_child: SGROUP(4), a = 3, EGROUP(4)
    }, bytes);

    var decoded = try decode(editions.Delimited, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(2, decoded.children.items.len);
    try testing.expectEqual(2, decoded.children.items[1].a);
    try testing.expectEqual(3, decoded.choice.?.oneof_child.a);
}

test "editions: length-prefixed overrides and map entries" {
    var msg: editions.Delimited = .{ .length_prefixed = .{ .a = 1 } };
    defer msg.by_name.deinit(testing.allocator);
    try msg.by_name.append(testing.allocator, .{ .key = "x", .value = .{ .a = 1 } });

    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x1A, 0x02, 0x08, 0x01, // length_prefixed: LEN(3), a = 1
        // by_name: LEN(6) entry { key = "x", value = LEN(2) { a = 1 } }
        0x32, 0x07, 0x0A, 0x01,
        'x',  0x12, 0x02, 0x08,
        0x01,
    }, bytes);

    var decoded = try decode(editions.Delimited, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(1, decoded.length_prefixed.?.a);
    try testing.expectEqualSlices(u8, "x", decoded.by_name.items[0].key);
    try testing.expectEqual(1, decoded.by_name.items[0].value.?.a);
}

test "editions: malformed groups are rejected" {
    // Missing EGROUP.
    try testing.expectError(error.EndOfStream, decode(editions.Delimited, &.{ 0x0B, 0x08, 0x01 }));
    // EGROUP of another field.
    try testing.expectError(error.InvalidInput, decode(editions.Delimited, &.{ 0x0B, 0x08, 0x01, 0x14 }));
    // EGROUP without SGROUP.
    try testing.expectError(error.InvalidInput, decode(editions.Delimited, &.{0x0C}));
    // Length-prefixed encoding of a delimited field.
    try testing.expectError(error.InvalidInput, decode(editions.Delimited, &.{ 0x0A, 0x02, 0x08, 0x01 }));
}

test "editions: field presence" {
    const msg: editions.Presence = .{ .explicit_int = 0, .implicit_int = 0, .required_int = 0 };
    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);

    // Explicit and required fields are written even when zero; implicit
    // presence fields are not.
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x00, 0x18, 0x00 }, bytes);

    var decoded = try decode(editions.Presence, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(0, decoded.explicit_int.?);
    try testing.expectEqual(null, decoded.defaulted_int);
    try testing.expectEqual(42, editions.Presence.defaults.defaulted_int);
}

test "editions: closed enums drop unknown values, open enums keep them" {
    var decoded = try decode(editions.Presence, &.{
        0x28, 0x05, // closed_enum = 5 (unknown)
        0x30, 0x07, // open_enum = 7 (unknown)
        0x3A, 0x03, 0x01, 0x07, 0x02, // closed_enums = [ONE, 7 (unknown), TWO]
    });
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(null, decoded.closed_enum);
    try testing.expectEqual(7, @intFromEnum(decoded.open_enum.?));
    try testing.expectEqualSlices(
        editions.Closed,
        &.{ .CLOSED_ONE, .CLOSED_TWO },
        decoded.closed_enums.items,
    );

    // Closed enums default to their first value, which need not be zero.
    try testing.expectEqual(.CLOSED_ONE, @import("protobuf").enumDefault(editions.Closed));
}

test "editions: repeated field encoding" {
    var msg: editions.Encoding = .{};
    defer msg.packed_ints.deinit(testing.allocator);
    defer msg.expanded_ints.deinit(testing.allocator);
    try msg.packed_ints.appendSlice(testing.allocator, &.{ 1, 2 });
    try msg.expanded_ints.appendSlice(testing.allocator, &.{ 1, 2 });

    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x0A, 0x02, 0x01, 0x02, // packed_ints: LEN(1) [1, 2]
        0x10, 0x01, 0x10, 0x02, // expanded_ints: VARINT(2) 1, VARINT(2) 2
    }, bytes);
}

test "editions: utf8 validation" {
    try testing.expectError(error.InvalidInput, decode(editions.Encoding, &.{ 0x1A, 0x01, 0xFF }));

    var decoded = try decode(editions.Encoding, &.{ 0x22, 0x01, 0xFF });
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{0xFF}, decoded.unverified.?);
}

const editions2026 = @import("./generated/tests/editions2026.pb.zig");

test "editions 2026: runtime features keep the edition 2023 defaults" {
    const Defaults = editions2026.Defaults;

    // Explicit presence, open enums.
    try testing.expectEqual(?i32, @FieldType(Defaults, "number"));
    try testing.expectEqual(?editions2026.Kind, @FieldType(Defaults, "kind"));
    try testing.expect(!@typeInfo(editions2026.Kind).@"enum".is_exhaustive);
    try testing.expectEqual(i32, @FieldType(Defaults, "implicit_number"));

    // Packed repeated fields, verified strings, length-prefixed submessages.
    try testing.expectEqual(.packed_repeated, std.meta.activeTag(Defaults._desc_table.numbers.ftype));
    try testing.expectEqual(.verify, Defaults._desc_table.text.features.utf8_validation);
    try testing.expectEqual(.length_prefixed, Defaults._desc_table.child.features.message_encoding);

    var msg: Defaults = .{ .number = 0, .child = .{ .a = 1 } };
    defer msg.numbers.deinit(testing.allocator);
    try msg.numbers.appendSlice(testing.allocator, &.{ 1, 2 });
    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x08, 0x00, // number = 0, written as it is set
        0x22, 0x02, 0x01, 0x02, // numbers: LEN(4) [1, 2]
        0x2A, 0x02, 0x08, 0x01, // child: LEN(5) { a = 1 }
    }, bytes);
}
