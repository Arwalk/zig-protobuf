const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const editions = @import("./generated/tests/editions.pb.zig");
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

test "dupe: repeated scalar bytes" {
    var my_bytes: std.ArrayList([]const u8) = try .initCapacity(testing.allocator, 2);
    try my_bytes.append(testing.allocator, try testing.allocator.dupe(u8, "hello"));
    try my_bytes.append(testing.allocator, try testing.allocator.dupe(u8, "world"));

    var msg: tests.WithRepeatedBytes = .{ .byte_field = my_bytes };
    defer msg.deinit(testing.allocator);

    var copy = try msg.dupe(testing.allocator);
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(msg.byte_field.items.len, copy.byte_field.items.len);
    try testing.expectEqualSlices(u8, msg.byte_field.items[0], copy.byte_field.items[0]);
    try testing.expectEqualSlices(u8, msg.byte_field.items[1], copy.byte_field.items[1]);
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

test "leak: an optional string sent twice frees the first value" {
    // Field 14 (optional_string) = "a", then again = "b": the last one wins.
    var reader: std.Io.Reader = .fixed("\x72\x01a\x72\x01b");
    var decoded = try unittest.TestAllTypes.decode(&reader, testing.allocator);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("b", decoded.optional_string.?);
}

test "leak: an optional bytes sent twice frees the first value" {
    // Field 15 (optional_bytes) = "a", then again = "b".
    var reader: std.Io.Reader = .fixed("\x7a\x01a\x7a\x01b");
    var decoded = try unittest.TestAllTypes.decode(&reader, testing.allocator);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("b", decoded.optional_bytes.?);
}

test "leak: a merged submessage frees the optional string it replaces" {
    // Field 3 (length_prefixed) of Delimited, sent twice: both occurrences
    // merge into one Child, whose field 2 (s) is "a" and then "b".
    var reader: std.Io.Reader = .fixed("\x1a\x03\x12\x01a\x1a\x03\x12\x01b");
    var decoded = try editions.Delimited.decode(&reader, testing.allocator);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("b", decoded.length_prefixed.?.s.?);
}

/// A message, not a list, whose fields have the names of the fields of
/// `std.ArrayList`: `message Stock { string items = 1; int32 capacity = 2; }`.
const Stock = struct {
    items: []const u8 = &.{},
    capacity: i32 = 0,

    pub const _desc_table = .{
        .items = protobuf.fd(1, .{ .scalar = .string }),
        .capacity = protobuf.fd(2, .{ .scalar = .int32 }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// `message Shelf { repeated string items = 1; int32 capacity = 2; }`.
const Shelf = struct {
    items: std.ArrayList([]const u8) = .empty,
    capacity: i32 = 0,

    pub const _desc_table = .{
        .items = protobuf.fd(1, .{ .repeated = .{ .scalar = .string } }),
        .capacity = protobuf.fd(2, .{ .scalar = .int32 }),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// `message Warehouse { Stock stock = 1; Shelf shelf = 2; }`.
const Warehouse = struct {
    stock: ?Stock = null,
    shelf: ?Shelf = null,

    pub const _desc_table = .{
        .stock = protobuf.fd(1, .submessage),
        .shelf = protobuf.fd(2, .submessage),
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

test "leak: a submessage with fields named items and capacity is not taken for a list" {
    // stock { items: "hi" capacity: 3 }
    // shelf { items: "a" items: "b" capacity: 2 }
    var reader: std.Io.Reader = .fixed("\x0a\x06\x0a\x02hi\x10\x03" ++ "\x12\x08\x0a\x01a\x0a\x01b\x10\x02");
    var decoded = try protobuf.decode(Warehouse, &reader, testing.allocator);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("hi", decoded.stock.?.items);
    try testing.expectEqual(3, decoded.stock.?.capacity);
    try testing.expectEqual(2, decoded.shelf.?.items.items.len);
    try testing.expectEqualStrings("b", decoded.shelf.?.items.items[1]);
}
