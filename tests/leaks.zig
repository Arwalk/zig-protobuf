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
    msg_copy.deinit(testing.allocator);
}

test "dupe does not leak on mid-duplication allocation failure" {
    // A nested submessage plus repeated submessages, so a mid-dupe OOM leaves
    // a partial duplicate.
    const Msg = tests.WithBytesNested;

    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var original: Msg = .{};
            defer original.deinit(alloc);

            // Allocate before the aggregate init, or a failing `try` inside it
            // leaves a half-written optional.
            const inner_bytes = try alloc.dupe(u8, "inner");
            original.inner = .{ .hex_field = inner_bytes };

            // Two items so a failure on the second leaves a partial list.
            for ([_][]const u8{ "item0", "item1" }) |s| {
                const bytes = try alloc.dupe(u8, s);
                errdefer alloc.free(bytes);
                try original.items.append(alloc, .{ .hex_field = bytes });
            }

            var copy = try protobuf.dupe(Msg, original, alloc);
            copy.deinit(alloc);
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Case.run,
        .{},
    );
}
