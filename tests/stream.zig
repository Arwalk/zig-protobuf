//! End-to-end tests for the streaming pull-decoder (`Message.StreamDecoder`),
//! exercising the code path generated into real `.pb.zig` message types.
//!
//! The decoder's internal logic is unit-tested with hand-written structs in
//! `src/stream.zig`; here we confirm the generator-emitted `StreamDecoder` const
//! works against actual generated messages, and that streamed values match the
//! canonical `decode`.

const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");

const tests = @import("./generated/tests.pb.zig");
const oneof = @import("./generated/tests/oneof.pb.zig");

/// Encode `msg` into an allocated buffer using the canonical encoder.
fn encodeToOwned(msg: anytype, allocator: std.mem.Allocator) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    errdefer w.deinit();
    try protobuf.encode(&w.writer, allocator, msg);
    return w.toOwnedSlice();
}

test "stream: FixedSizes scalars" {
    const src: tests.FixedSizes = .{
        .sfixed64 = -42,
        .sfixed32 = -7,
        .fixed32 = 123456,
        .fixed64 = 1 << 50,
        .double = 3.14159,
        .float = 2.5,
    };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = tests.FixedSizes.StreamDecoder.init(&reader);

    var got: tests.FixedSizes = .{};
    while (try sd.next()) |item| switch (item) {
        .sfixed64 => |v| got.sfixed64 = v,
        .sfixed32 => |v| got.sfixed32 = v,
        .fixed32 => |v| got.fixed32 = v,
        .fixed64 => |v| got.fixed64 = v,
        .double => |v| got.double = v,
        .float => |v| got.float = v,
    };
    try testing.expectEqual(src, got);
}

test "stream: WithStrings hands out a limited reader" {
    const src: tests.WithStrings = .{ .name = "streaming!" };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = tests.WithStrings.StreamDecoder.init(&reader);

    const ev = (try sd.next()).?;
    var buf: [32]u8 = undefined;
    const n = try ev.name.readSliceShort(&buf);
    try testing.expectEqualStrings("streaming!", buf[0..n]);

    try testing.expectEqual(@as(?tests.WithStrings.StreamDecoder.Event, null), try sd.next());
}

test "stream: Packed repeated emits one event per element, matching decode" {
    var src: tests.Packed = .{};
    defer src.deinit(testing.allocator);
    try src.uint32_list.appendSlice(testing.allocator, &.{ 1, 2, 300, 70000 });
    try src.sint64_list.appendSlice(testing.allocator, &.{ -1, -2, 3 });
    try src.bool_list.appendSlice(testing.allocator, &.{ true, false, true });
    try src.enum_list.appendSlice(testing.allocator, &.{ .SE_ZERO, .SE2_ONE });

    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = tests.Packed.StreamDecoder.init(&reader);

    var rebuilt: tests.Packed = .{};
    defer rebuilt.deinit(testing.allocator);
    while (try sd.next()) |item| switch (item) {
        .uint32_list => |v| try rebuilt.uint32_list.append(testing.allocator, v),
        .sint64_list => |v| try rebuilt.sint64_list.append(testing.allocator, v),
        .bool_list => |v| try rebuilt.bool_list.append(testing.allocator, v),
        .enum_list => |v| try rebuilt.enum_list.append(testing.allocator, v),
        else => {},
    };

    try testing.expectEqualSlices(u32, src.uint32_list.items, rebuilt.uint32_list.items);
    try testing.expectEqualSlices(i64, src.sint64_list.items, rebuilt.sint64_list.items);
    try testing.expectEqualSlices(bool, src.bool_list.items, rebuilt.bool_list.items);
    try testing.expectEqualSlices(tests.TopLevelEnum, src.enum_list.items, rebuilt.enum_list.items);
}

test "stream: submessage recursed via a nested decoder" {
    const src: tests.WithSubmessages = .{ .with_enum = .{ .value = .B } };
    const bytes = try encodeToOwned(src, testing.allocator);
    defer testing.allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var sd = tests.WithSubmessages.StreamDecoder.init(&reader);

    const ev = (try sd.next()).?;
    var inner = tests.WithEnum.StreamDecoder.init(ev.with_enum);
    var got: tests.WithEnum.SomeEnum = @enumFromInt(0);
    while (try inner.next()) |item| switch (item) {
        .value => |v| got = v,
    };
    try testing.expectEqual(tests.WithEnum.SomeEnum.B, got);

    try testing.expectEqual(@as(?tests.WithSubmessages.StreamDecoder.Event, null), try sd.next());
}

test "stream: oneof cases flatten into top-level events (scalar + enum)" {
    {
        const src: oneof.OneofContainer = .{
            .regular_field = "reg",
            .enum_field = .SOMETHING,
            .some_oneof = .{ .a_number = 1234 },
        };
        const bytes = try encodeToOwned(src, testing.allocator);
        defer testing.allocator.free(bytes);

        var reader: std.Io.Reader = .fixed(bytes);
        var sd = oneof.OneofContainer.StreamDecoder.init(&reader);

        var saw_number = false;
        var saw_enum = false;
        while (try sd.next()) |item| switch (item) {
            .a_number => |v| {
                try testing.expectEqual(@as(i32, 1234), v);
                saw_number = true;
            },
            .enum_field => |v| {
                try testing.expectEqual(oneof.Enum.SOMETHING, v);
                saw_enum = true;
            },
            // regular_field (string) is a limited reader we leave unread.
            else => {},
        };
        try testing.expect(saw_number and saw_enum);
    }
    {
        // oneof submessage case is surfaced as a limited reader to recurse into.
        const src: oneof.OneofContainer = .{
            .some_oneof = .{ .message_in_oneof = .{ .value = 7, .str = "x" } },
        };
        const bytes = try encodeToOwned(src, testing.allocator);
        defer testing.allocator.free(bytes);

        var reader: std.Io.Reader = .fixed(bytes);
        var sd = oneof.OneofContainer.StreamDecoder.init(&reader);

        var inner_value: i32 = 0;
        while (try sd.next()) |item| switch (item) {
            .message_in_oneof => |limited| {
                var inner = oneof.Message.StreamDecoder.init(limited);
                while (try inner.next()) |x| switch (x) {
                    .value => |v| inner_value = v,
                    else => {},
                };
            },
            else => {},
        };
        try testing.expectEqual(@as(i32, 7), inner_value);
    }
}
