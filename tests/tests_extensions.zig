const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const ext = @import("./generated/tests/extensions.pb.zig");
const ext_editions = @import("./generated/tests/extensions/editions.pb.zig");

const registry: protobuf.ExtensionRegistry = .init(ext.extensions ++ ext_editions.extensions);

fn encode(msg: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    try msg.encode(&w.writer, testing.allocator);
    return w.toOwnedSlice();
}

fn decode(comptime T: type, bytes: []const u8, options: protobuf.DecodeOptions) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decodeWithOptions(T, &reader, testing.allocator, options);
}

test "extensions: set, get, has and clear" {
    var msg: ext.Extendable = .{ .regular = 1 };
    defer msg.deinit(testing.allocator);

    try testing.expect(!ext.number.has(msg));
    try testing.expectEqual(null, try ext.number.get(msg, testing.allocator));

    try ext.number.set(&msg, testing.allocator, 0);
    try testing.expect(ext.number.has(msg));
    try testing.expectEqual(0, (try ext.number.get(msg, testing.allocator)).?);

    // Setting again replaces the value.
    try ext.number.set(&msg, testing.allocator, 7);
    try testing.expectEqual(7, (try ext.number.get(msg, testing.allocator)).?);

    try ext.Scope.scoped.set(&msg, testing.allocator, -1);
    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x08, 0x01, // regular = 1
        0xA0, 0x06, 0x07, // number (100) = 7
        0xC0, 0x3E, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, // scoped (1000) = -1
    }, bytes);

    try ext.number.clear(&msg, testing.allocator);
    try testing.expect(!ext.number.has(msg));
    try testing.expect(ext.Scope.scoped.has(msg));
}

test "extensions: default values" {
    const msg: ext.Extendable = .{};
    try testing.expectEqual(null, try ext.text.get(msg, testing.allocator));
    try testing.expectEqualSlices(u8, "none", ext.text.default);
    try testing.expectEqual(null, ext.number.default);
}

test "extensions: repeated, message, group and enum values" {
    var msg: ext.Extendable = .{};
    defer msg.deinit(testing.allocator);

    var numbers: std.ArrayList(i32) = .empty;
    defer numbers.deinit(testing.allocator);
    try numbers.appendSlice(testing.allocator, &.{ 1, 2 });
    try ext.packed_numbers.set(&msg, testing.allocator, numbers);
    try ext.payload.set(&msg, testing.allocator, .{ .a = 3 });
    try ext.grouped.set(&msg, testing.allocator, .{ .g = 4 });
    try ext.color.set(&msg, testing.allocator, .GREEN);

    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0xB2, 0x06, 0x02, 0x01, 0x02, // packed_numbers (102): LEN [1, 2]
        0xBA, 0x06, 0x02, 0x08, 0x03, // payload (103): LEN { a = 3 }
        0xC3, 0x06, 0x08, 0x04, 0xC4, 0x06, // grouped (104): SGROUP { g = 4 } EGROUP
        0xC8, 0x06, 0x02, // color (105) = GREEN
    }, bytes);

    var decoded = try decode(ext.Extendable, bytes, .{});
    defer decoded.deinit(testing.allocator);

    var got_numbers = try ext.packed_numbers.get(decoded, testing.allocator);
    defer ext.packed_numbers.deinitValue(&got_numbers, testing.allocator);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, got_numbers.items);
    try testing.expectEqual(3, (try ext.payload.get(decoded, testing.allocator)).?.a);
    try testing.expectEqual(4, (try ext.grouped.get(decoded, testing.allocator)).?.g);
    try testing.expectEqual(.GREEN, (try ext.color.get(decoded, testing.allocator)).?);
}

test "extensions: fields outside the extension ranges are not extensions" {
    // Field 50 is neither a field nor in an extension range; field 100 is.
    var decoded = try decode(ext.Extendable, &.{ 0x90, 0x03, 0x01, 0xA0, 0x06, 0x05 }, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0xA0, 0x06, 0x05 }, decoded._extensions);
    try testing.expectEqual(5, (try ext.number.get(decoded, testing.allocator)).?);
}

test "extensions: repeated occurrences are merged" {
    // Two occurrences of the payload extension: `a` of the last one wins.
    var decoded = try decode(ext.Extendable, &.{ 0xBA, 0x06, 0x02, 0x08, 0x01, 0xBA, 0x06, 0x02, 0x08, 0x02 }, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(2, (try ext.payload.get(decoded, testing.allocator)).?.a);
}

test "extensions: a registry validates known extensions when decoding" {
    // checked (150) holds invalid UTF-8.
    const invalid: []const u8 = &.{ 0xB2, 0x09, 0x01, 0xFF };
    try testing.expectError(error.InvalidInput, decode(ext.Extendable, invalid, .{ .extensions = &registry }));

    // Without a registry, the extension is only decoded when accessed.
    var decoded = try decode(ext.Extendable, invalid, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectError(error.InvalidInput, ext_editions.checked.get(decoded, testing.allocator));

    // Bytes are never validated.
    var bytes = try decode(ext.Extendable, &.{ 0xBA, 0x09, 0x01, 0xFF }, .{ .extensions = &registry });
    defer bytes.deinit(testing.allocator);
    var value = try ext_editions.unchecked.get(bytes, testing.allocator);
    defer ext_editions.unchecked.deinitValue(&value, testing.allocator);
    try testing.expectEqualSlices(u8, &.{0xFF}, value.?);
}

test "extensions: JSON" {
    var msg: ext.Extendable = .{ .regular = 1 };
    defer msg.deinit(testing.allocator);
    try ext.number.set(&msg, testing.allocator, 7);
    try ext.payload.set(&msg, testing.allocator, .{ .a = 3 });

    // Only known extensions are written.
    const without = try msg.jsonEncode(.{}, .{}, testing.allocator);
    defer testing.allocator.free(without);
    try testing.expectEqualStrings("{\"regular\":1}", without);

    const json = try msg.jsonEncode(.{}, .{ .extensions = &registry }, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"regular\":1,\"[tests.extensions.number]\":7,\"[tests.extensions.payload]\":{\"a\":3}}",
        json,
    );

    const parsed = try protobuf.json.decodeWithOptions(ext.Extendable, json, .{}, .{ .extensions = &registry }, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(1, parsed.value.regular.?);
    try testing.expectEqual(7, (try ext.number.get(parsed.value, testing.allocator)).?);
    try testing.expectEqual(3, (try ext.payload.get(parsed.value, testing.allocator)).?.a);

    // Without a registry, extension names are unknown fields.
    try testing.expectError(error.UnknownField, ext.Extendable.jsonDecode(json, .{}, testing.allocator));
}

test "extensions: MessageSet wire format" {
    var msg: ext.MessageSet = .{};
    defer msg.deinit(testing.allocator);
    try ext.SetItem.item.set(&msg, testing.allocator, .{ .i = 5 });

    const bytes = try encode(msg);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x0B, // SGROUP(1)
        0x10, 0xD2, 0x09, // type_id (2) = 1234
        0x1A, 0x02, 0x08, 0x05, // message (3): LEN { i = 5 }
        0x0C, // EGROUP(1)
    }, bytes);

    var decoded = try decode(ext.MessageSet, bytes, .{ .extensions = &registry });
    defer decoded.deinit(testing.allocator);
    var item = try ext.SetItem.item.get(decoded, testing.allocator);
    defer ext.SetItem.item.deinitValue(&item, testing.allocator);
    try testing.expectEqual(5, item.?.i);
}

test "two oneofs: fields of the second oneof are decoded" {
    var decoded = try decode(ext.TwoOneofs, &.{ 0x08, 0x01, 0x18, 0x02 }, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(1, decoded.first.?.a);
    try testing.expectEqual(2, decoded.second.?.c);
}

test "extensions: JSON skips empty repeated extensions" {
    // packed_numbers (102) as an empty LEN record.
    var msg = try decode(ext.Extendable, &.{ 0xB2, 0x06, 0x00 }, .{});
    defer msg.deinit(testing.allocator);
    try testing.expect(ext.packed_numbers.has(msg));

    const json = try msg.jsonEncode(.{}, .{ .extensions = &registry }, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{}", json);
}
