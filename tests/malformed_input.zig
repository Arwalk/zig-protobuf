//! Decoding malformed input: each case must fail cleanly, without an
//! allocation sized by an unchecked length and without unbounded recursion.
const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const selfref = @import("./generated/selfref.pb.zig");
const ext = @import("./generated/tests/extensions.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const merge = @import("./generated/tests/merge.pb.zig");

/// Fails every single allocation larger than `max`, standing in for a
/// memory-bounded process.
const CappedAllocator = struct {
    child: std.mem.Allocator = testing.allocator,
    max: usize = 1 << 20,

    fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.max) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Decodes `bytes` as a `T` with a capped allocator; the message, if any,
/// is freed.
fn decodeCapped(comptime T: type, bytes: []const u8) !void {
    var capped: CappedAllocator = .{};
    const gpa = capped.allocator();
    var reader: std.Io.Reader = .fixed(bytes);
    var msg = try T.decode(&reader, gpa);
    msg.deinit(gpa);
}

/// `decodeCapped` with decode options and an allocation cap.
fn decodeCappedWith(comptime T: type, bytes: []const u8, options: protobuf.DecodeOptions, max: usize) !void {
    var capped: CappedAllocator = .{ .max = max };
    const gpa = capped.allocator();
    var reader: std.Io.Reader = .fixed(bytes);
    var msg = try protobuf.decodeWithOptions(T, &reader, gpa, options);
    msg.deinit(gpa);
}

test "malformed input: a length prefix larger than the input is not allocated" {
    // Field 1, length 2^31 - 1, and no data.
    const huge = "\x0a\xff\xff\xff\xff\x07";
    try testing.expectError(error.EndOfStream, decodeCapped(tests.WithStrings, huge));
    try testing.expectError(error.EndOfStream, decodeCapped(tests.WithBytes, huge));
    try testing.expectError(error.EndOfStream, decodeCapped(tests.WithRepeatedStrings, huge));
    try testing.expectError(error.EndOfStream, decodeCapped(tests.WithRepeatedBytes, huge));
    // The same in a oneof member (string_in_oneof is field 1).
    try testing.expectError(error.EndOfStream, decodeCapped(tests_oneof.OneofContainer, huge));
    // A MessageSet item whose message (field 3) claims 2^31 - 1 bytes.
    try testing.expectError(error.EndOfStream, decodeCapped(ext.MessageSet, "\x0b\x1a\xff\xff\xff\xff\x07"));
    // An unknown field in an extension range (field 100), kept as raw bytes.
    try testing.expectError(error.EndOfStream, decodeCapped(ext.Extendable, "\xa2\x06\xff\xff\xff\xff\x07"));
}

test "malformed input: long values still decode from a reader that holds little at a time" {
    const gpa = testing.allocator;
    const text = try gpa.alloc(u8, 200_000);
    defer gpa.free(text);
    @memset(text, 'x');
    const original: tests.WithStrings = .{ .name = text };
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try original.encode(&w.writer, gpa);

    var buffer: [16]u8 = undefined;
    var stream: testing.Reader = .init(&buffer, &.{.{ .buffer = w.written() }});
    stream.artificial_limit = .limited(7);
    var decoded = try tests.WithStrings.decode(&stream.interface, gpa);
    defer decoded.deinit(gpa);
    try testing.expectEqualStrings(text, decoded.name);
}

/// `depth` start-group tags of unknown field 2, then the matching end-group
/// tags.
fn nestedGroups(gpa: std.mem.Allocator, depth: usize, comptime field: u8) ![]u8 {
    const out = try gpa.alloc(u8, depth * 2);
    @memset(out[0..depth], field << 3 | 3);
    @memset(out[depth..], field << 3 | 4);
    return out;
}

test "malformed input: unknown groups nest at most default_recursion_limit deep" {
    const gpa = testing.allocator;
    // Deep enough to overflow any stack if each level recursed.
    const deep = try gpa.alloc(u8, 2_000_000);
    defer gpa.free(deep);
    @memset(deep, 2 << 3 | 3);
    try testing.expectError(error.InvalidInput, decodeCapped(tests.WithStrings, deep));
    // Kept as extension records (field 100 is in Extendable's range).
    const deep_ext = try gpa.alloc(u8, 2_000_000);
    defer gpa.free(deep_ext);
    for (0..deep_ext.len / 2) |i| {
        deep_ext[2 * i] = 0xa3; // field 100, start group
        deep_ext[2 * i + 1] = 0x06;
    }
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, deep_ext));

    // Within the limit, the groups are skipped as before.
    const ok = try nestedGroups(gpa, protobuf.wire.default_recursion_limit, 2);
    defer gpa.free(ok);
    try decodeCapped(tests.WithStrings, ok);
    const too_deep = try nestedGroups(gpa, protobuf.wire.default_recursion_limit + 1, 2);
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCapped(tests.WithStrings, too_deep));
}

/// A `SelfRefNode` nested `depth` deep, encoded.
fn nestedNodes(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    return nestedNodesAround(gpa, depth, "\x08\x01"); // version = 1
}

/// A `SelfRefNode` nested `depth` deep around the fields `innermost`, encoded.
fn nestedNodesAround(gpa: std.mem.Allocator, depth: usize, innermost: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, innermost);
    for (0..depth) |_| {
        var prefix: [11]u8 = undefined;
        var w: std.Io.Writer = .fixed(&prefix);
        w.writeByte(0x12) catch unreachable; // field 2, length-delimited
        w.writeUleb128(bytes.items.len) catch unreachable;
        try bytes.insertSlice(gpa, 0, w.buffered());
    }
    return bytes.toOwnedSlice(gpa);
}

test "malformed input: recursive messages nest at most default_recursion_limit deep" {
    const gpa = testing.allocator;
    const ok = try nestedNodes(gpa, protobuf.wire.default_recursion_limit);
    defer gpa.free(ok);
    try decodeCapped(selfref.SelfRefNode, ok);

    const too_deep = try nestedNodes(gpa, protobuf.wire.default_recursion_limit + 1);
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCapped(selfref.SelfRefNode, too_deep));
}

test "malformed input: recursion_limit option bounds messages and groups" {
    const gpa = testing.allocator;
    const limit: protobuf.DecodeOptions = .{ .recursion_limit = 3 };

    // Recursive messages.
    const nodes_ok = try nestedNodes(gpa, 3);
    defer gpa.free(nodes_ok);
    try decodeCappedWith(selfref.SelfRefNode, nodes_ok, limit, 1 << 20);
    const nodes_deep = try nestedNodes(gpa, 4);
    defer gpa.free(nodes_deep);
    try testing.expectError(error.InvalidInput, decodeCappedWith(selfref.SelfRefNode, nodes_deep, limit, 1 << 20));
    // A limit of 0 allows the outermost message only.
    const one = try nestedNodes(gpa, 1);
    defer gpa.free(one);
    try decodeCappedWith(selfref.SelfRefNode, one[2..], .{ .recursion_limit = 0 }, 1 << 20);
    try testing.expectError(error.InvalidInput, decodeCappedWith(selfref.SelfRefNode, one, .{ .recursion_limit = 0 }, 1 << 20));

    // Unknown groups, skipped.
    const groups_ok = try nestedGroups(gpa, 3, 2);
    defer gpa.free(groups_ok);
    try decodeCappedWith(tests.WithStrings, groups_ok, limit, 1 << 20);
    const groups_deep = try nestedGroups(gpa, 4, 2);
    defer gpa.free(groups_deep);
    try testing.expectError(error.InvalidInput, decodeCappedWith(tests.WithStrings, groups_deep, limit, 1 << 20));

    // Groups in an extension range (field 100), kept as extension records.
    const start_100 = "\xa3\x06";
    const end_100 = "\xa4\x06";
    try decodeCappedWith(ext.Extendable, start_100 ++ start_100 ++ start_100 ++ end_100 ++ end_100 ++ end_100, limit, 1 << 20);
    try testing.expectError(error.InvalidInput, decodeCappedWith(ext.Extendable, start_100 ++ start_100 ++ start_100 ++ start_100 ++ end_100 ++ end_100 ++ end_100 ++ end_100, limit, 1 << 20));

    // Unknown groups (field 4) in a MessageSet item, which is a group itself.
    try decodeCappedWith(ext.MessageSet, "\x0b\x23\x23\x24\x24\x0c", limit, 1 << 20);
    try testing.expectError(error.InvalidInput, decodeCappedWith(ext.MessageSet, "\x0b\x23\x23\x23\x24\x24\x24\x0c", limit, 1 << 20));
}

/// An extension of `Extendable` holding an `Extendable`, so that extensions
/// nest without bound in the input.
const nested_extension = protobuf.Extension(ext.Extendable, ?ext.Extendable, protobuf.fd(107, .submessage), "tests.malformed.nested", null, .{});

/// An `Extendable` whose `nested_extension` is set `depth` deep, encoded.
fn nestedExtensions(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, "\x08\x01"); // regular = 1
    for (0..depth) |_| {
        var prefix: [12]u8 = undefined;
        var w: std.Io.Writer = .fixed(&prefix);
        w.writeAll("\xda\x06") catch unreachable; // field 107, length-delimited
        w.writeUleb128(bytes.items.len) catch unreachable;
        try bytes.insertSlice(gpa, 0, w.buffered());
    }
    return bytes.toOwnedSlice(gpa);
}

test "malformed input: known extensions count toward the recursion limit" {
    const gpa = testing.allocator;
    const registry: protobuf.ExtensionRegistry = .init(.{nested_extension});

    const ok = try nestedExtensions(gpa, 3);
    defer gpa.free(ok);
    try decodeCappedWith(ext.Extendable, ok, .{ .extensions = &registry, .recursion_limit = 3 }, 1 << 20);
    const too_deep = try nestedExtensions(gpa, 4);
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCappedWith(ext.Extendable, too_deep, .{ .extensions = &registry, .recursion_limit = 3 }, 1 << 20));
    // Without a registry the extensions stay raw records.
    try decodeCappedWith(ext.Extendable, too_deep, .{ .recursion_limit = 3 }, 1 << 20);

    // With the default limit.
    const default_ok = try nestedExtensions(gpa, protobuf.wire.default_recursion_limit);
    defer gpa.free(default_ok);
    try decodeCappedWith(ext.Extendable, default_ok, .{ .extensions = &registry }, 1 << 20);
    const default_deep = try nestedExtensions(gpa, protobuf.wire.default_recursion_limit + 1);
    defer gpa.free(default_deep);
    try testing.expectError(error.InvalidInput, decodeCappedWith(ext.Extendable, default_deep, .{ .extensions = &registry }, 1 << 20));
}

test "malformed input: recursion_limit option bounds JSON Values" {
    const gpa = testing.allocator;
    const Value = protobuf.wkt.Value;
    const parsed = try protobuf.json.decodeWithOptions(Value, "[[1]]", .{}, .{ .recursion_limit = 3 }, gpa);
    parsed.deinit();
    try testing.expectError(error.SyntaxError, protobuf.json.decodeWithOptions(Value, "[[[1]]]", .{}, .{ .recursion_limit = 3 }, gpa));
    // The limit applies only within the call.
    const again = try Value.jsonDecode("[[[1]]]", .{}, gpa);
    again.deinit();
}

test "malformed input: read_chunk option" {
    const gpa = testing.allocator;
    const small: protobuf.DecodeOptions = .{ .read_chunk = 16 };

    // A length prefix larger than the input fails before much more than a
    // chunk is allocated (the list may round its first allocation up).
    const huge = "\x0a\xff\xff\xff\xff\x07";
    const cap = 1024;
    try testing.expectError(error.EndOfStream, decodeCappedWith(tests.WithStrings, huge, small, cap));
    try testing.expectError(error.EndOfStream, decodeCappedWith(tests.WithRepeatedBytes, huge, small, cap));
    try testing.expectError(error.EndOfStream, decodeCappedWith(ext.MessageSet, "\x0b\x1a\xff\xff\xff\xff\x07", small, cap));
    try testing.expectError(error.EndOfStream, decodeCappedWith(ext.Extendable, "\xa2\x06\xff\xff\xff\xff\x07", small, cap));
    // The default chunk is larger than that cap.
    try testing.expectError(error.OutOfMemory, decodeCappedWith(tests.WithStrings, huge, .{}, cap));
    // A prefix just past the input: everything that arrived is read first.
    try testing.expectError(error.EndOfStream, decodeCappedWith(tests.WithBytes, "\x0a\x40" ++ @as([63]u8, @splat('y')), small, 1 << 20));

    // Long values still decode, chunk by chunk, also from a reader that holds
    // little at a time and with a chunk of 0 (taken as 1).
    const text = try gpa.alloc(u8, 100_000);
    defer gpa.free(text);
    for (text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    const original: tests.WithBytes = .{ .byte_field = text };
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try original.encode(&w.writer, gpa);

    for ([_]usize{ 16, 0 }) |chunk| {
        var buffer: [16]u8 = undefined;
        var stream: testing.Reader = .init(&buffer, &.{.{ .buffer = w.written() }});
        stream.artificial_limit = .limited(7);
        var decoded = try protobuf.decodeWithOptions(tests.WithBytes, &stream.interface, gpa, .{ .read_chunk = chunk });
        defer decoded.deinit(gpa);
        try testing.expectEqualSlices(u8, text, decoded.byte_field);
    }
    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try protobuf.decodeWithOptions(tests.WithBytes, &reader, gpa, small);
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, text, decoded.byte_field);
}

test "malformed input: varints of unknown fields are at most 10 bytes" {
    // Field 100 (in Extendable's extension range): a length of 11 bytes,
    // then a varint of 11 bytes.
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, "\xa2\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01"));
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, "\xa0\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01"));
    // Ten bytes are fine.
    try decodeCapped(ext.Extendable, "\xa0\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01");
}

test "malformed input: Timestamp fields out of range are refused" {
    const gpa = testing.allocator;
    const Timestamp = protobuf.wkt.Timestamp;
    for ([_][]const u8{
        "\"2024-03-00T00:00:00Z\"",
        "\"2024-01-00T00:00:00Z\"",
        "\"2024-00-10T00:00:00Z\"",
        "\"2024-13-01T00:00:00Z\"",
        "\"2023-02-29T00:00:00Z\"",
        "\"1900-02-29T00:00:00Z\"",
        "\"2024-04-31T00:00:00Z\"",
        "\"2024-01-32T00:00:00Z\"",
        "\"2024-01-01T24:00:00Z\"",
        "\"2024-01-01T00:60:00Z\"",
        "\"2024-01-01T00:00:61Z\"",
        // Leap seconds are refused, as by the reference implementations.
        "\"2024-01-01T12:34:60Z\"",
        "\"2016-12-31T23:59:60Z\"",
        "\"2016-12-31T23:59:60.5Z\"",
        "\"2024-01-01T00:00:00+24:00\"",
        "\"2024-01-01T00:00:00+00:60\"",
        "\"2024-+1-01T00:00:00Z\"",
        "\"+024-01-01T00:00:00Z\"",
        "\"2024-01-01T00:00:00.+5Z\"",
        "\"2024-01-01T00:00:00+-1:00\"",
    }) |text| {
        if (Timestamp.jsonDecode(text, .{}, gpa)) |parsed| {
            parsed.deinit();
            std.debug.print("accepted {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    for ([_]struct { []const u8, i64 }{
        .{ "\"2024-02-29T00:00:00Z\"", 1709164800 },
        .{ "\"2000-02-29T12:30:45Z\"", 951827445 },
        .{ "\"2023-04-30T00:00:00Z\"", 1682812800 },
        .{ "\"0001-01-01T00:00:00Z\"", -62135596800 },
        .{ "\"9999-12-31T23:59:59Z\"", 253402300799 },
        .{ "\"2016-12-31T23:59:59Z\"", 1483228799 },
        .{ "\"1970-01-01T01:00:00+01:00\"", 0 },
    }) |case| {
        const parsed = try Timestamp.jsonDecode(case[0], .{}, gpa);
        defer parsed.deinit();
        try testing.expectEqual(case[1], parsed.value.seconds);
    }
}

test "malformed input: a captured length must fit an int32" {
    // Field 100 (in Extendable's extension range), length 2^31 and no data:
    // refused like everywhere else, rather than kept as a record that later
    // passes over the records cannot read back.
    const len_2_31 = "\xa2\x06\x80\x80\x80\x80\x08";
    try testing.expectError(error.InvalidInput, decodeCappedWith(ext.Extendable, len_2_31, .{ .read_chunk = 16 }, 1024));
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, len_2_31));
}

/// Decodes `bytes` as a `T` (see `decodeCapped`).
fn decoder(comptime T: type) fn ([]const u8) anyerror!void {
    return struct {
        fn decode(bytes: []const u8) anyerror!void {
            return decodeCapped(T, bytes);
        }
    }.decode;
}

/// Pulls every event of `bytes` from a `T.StreamDecoder`, reading the
/// length-delimited values to their end.
fn streamer(comptime T: type) fn ([]const u8) anyerror!void {
    return struct {
        fn decode(bytes: []const u8) anyerror!void {
            var reader: std.Io.Reader = .fixed(bytes);
            var sd = T.StreamDecoder.init(&reader);
            while (try sd.next()) |event| switch (event) {
                inline else => |value| if (@TypeOf(value) == *std.Io.Reader) {
                    _ = try value.discardRemaining();
                },
            };
        }
    }.decode;
}

/// Checks the length prefix of a field: `prefix`, the length, `payload`,
/// then `suffix` decode with the true length of `payload`, and fail with
/// `error.InvalidInput` for any length that does not fit an int32, including
/// those equal to the true length modulo 2^32.
fn expectLengthChecked(
    comptime decode: fn ([]const u8) anyerror!void,
    prefix: []const u8,
    payload: []const u8,
    suffix: []const u8,
) !void {
    const lengths = [_]u64{ payload.len, (1 << 32) + payload.len, 1 << 32, 1 << 31, std.math.maxInt(u64) };
    for (lengths, 0..) |len, i| {
        var buffer: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try w.writeAll(prefix);
        try w.writeUleb128(len);
        try w.writeAll(payload);
        try w.writeAll(suffix);
        if (i == 0) {
            try decode(w.buffered());
        } else if (decode(w.buffered())) {
            std.debug.print("accepted length {d} after {x}\n", .{ len, prefix });
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidInput, err);
    }
}

test "malformed input: length prefixes must fit an int32" {
    // Strings and bytes.
    try expectLengthChecked(decoder(tests.WithStrings), "\x0a", "A", "");
    try expectLengthChecked(decoder(tests.WithBytes), "\x0a", "A", "");
    try expectLengthChecked(decoder(tests.WithRepeatedStrings), "\x0a", "A", "");
    try expectLengthChecked(decoder(tests_oneof.OneofContainer), "\x0a", "A", "");
    // Packed repeated values.
    try expectLengthChecked(decoder(tests.Packed), "\x0a", "\x01", "");
    // Submessages, also in a oneof.
    try expectLengthChecked(decoder(selfref.SelfRefNode), "\x12", "\x08\x01", "");
    try expectLengthChecked(decoder(tests_oneof.OneofContainer), "\x12", "\x08\x01", "");
    // Unknown fields, skipped or kept as extension records.
    try expectLengthChecked(decoder(tests.WithStrings), "\x12", "A", "");
    try expectLengthChecked(decoder(ext.Extendable), "\xa2\x06", "A", "");
    // The message of a MessageSet item.
    try expectLengthChecked(decoder(ext.MessageSet), "\x0b\x1a", "A", "\x0c");
    // Streamed values.
    try expectLengthChecked(streamer(tests.WithStrings), "\x0a", "A", "");
    try expectLengthChecked(streamer(tests.Packed), "\x0a", "\x01", "");
}

test "malformed input: empty submessages count toward the recursion limit" {
    const gpa = testing.allocator;
    // The innermost node is empty (length 0), so it has no fields to decode.
    const ok = try nestedNodesAround(gpa, protobuf.wire.default_recursion_limit, "");
    defer gpa.free(ok);
    try decodeCapped(selfref.SelfRefNode, ok);
    const too_deep = try nestedNodesAround(gpa, protobuf.wire.default_recursion_limit + 1, "");
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCapped(selfref.SelfRefNode, too_deep));

    const limit: protobuf.DecodeOptions = .{ .recursion_limit = 3 };
    const three = try nestedNodesAround(gpa, 3, "");
    defer gpa.free(three);
    try decodeCappedWith(selfref.SelfRefNode, three, limit, 1 << 20);
    const four = try nestedNodesAround(gpa, 4, "");
    defer gpa.free(four);
    try testing.expectError(error.InvalidInput, decodeCappedWith(selfref.SelfRefNode, four, limit, 1 << 20));
    // A limit of 0 refuses even one empty submessage.
    try testing.expectError(error.InvalidInput, decodeCappedWith(selfref.SelfRefNode, "\x12\x00", .{ .recursion_limit = 0 }, 1 << 20));
    // The same in a oneof (message_in_oneof is field 2).
    try decodeCappedWith(tests_oneof.OneofContainer, "\x12\x00", .{ .recursion_limit = 1 }, 1 << 20);
    try testing.expectError(error.InvalidInput, decodeCappedWith(tests_oneof.OneofContainer, "\x12\x00", .{ .recursion_limit = 0 }, 1 << 20));
}

/// `open` `depth` times, `inner`, then `close` `depth` times.
fn nestedJson(gpa: std.mem.Allocator, depth: usize, open: []const u8, inner: []const u8, close: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (0..depth) |_| try text.appendSlice(gpa, open);
    try text.appendSlice(gpa, inner);
    for (0..depth) |_| try text.appendSlice(gpa, close);
    return text.toOwnedSlice(gpa);
}

/// Decodes the JSON `text` as a `T` with `options`; the message is freed.
fn decodeJson(comptime T: type, text: []const u8, options: protobuf.DecodeOptions) !void {
    const parsed = try protobuf.json.decodeWithOptions(T, text, .{}, options, testing.allocator);
    parsed.deinit();
}

test "malformed input: JSON messages nest at most recursion_limit deep" {
    const gpa = testing.allocator;
    const Node = selfref.SelfRefNode;
    const limit = protobuf.wire.default_recursion_limit;

    // As deep as the binary decoder allows, and one level deeper.
    const ok = try nestedJson(gpa, limit, "{\"node\":", "{}", "}");
    defer gpa.free(ok);
    try decodeJson(Node, ok, .{});
    for ([_]usize{ limit + 1, 250, 100_000 }) |depth| {
        const too_deep = try nestedJson(gpa, depth, "{\"node\":", "{}", "}");
        defer gpa.free(too_deep);
        try testing.expectError(error.SyntaxError, decodeJson(Node, too_deep, .{}));
    }
    // The depth starts over after a failure.
    try decodeJson(Node, ok, .{});

    // A custom limit.
    const three = try nestedJson(gpa, 3, "{\"node\":", "{}", "}");
    defer gpa.free(three);
    try decodeJson(Node, three, .{ .recursion_limit = 3 });
    const four = try nestedJson(gpa, 4, "{\"node\":", "{}", "}");
    defer gpa.free(four);
    try testing.expectError(error.SyntaxError, decodeJson(Node, four, .{ .recursion_limit = 3 }));

    // Messages around Values: each is bounded by the limit.
    const Msg = proto3.TestAllTypesProto3;
    const mixed_ok = try nestedJson(gpa, 3, "{\"recursiveMessage\":", "{\"optionalValue\":[[1]]}", "}");
    defer gpa.free(mixed_ok);
    try decodeJson(Msg, mixed_ok, .{ .recursion_limit = 3 });
    const deep_value = try nestedJson(gpa, 3, "{\"recursiveMessage\":", "{\"optionalValue\":[[[1]]]}", "}");
    defer gpa.free(deep_value);
    try testing.expectError(error.SyntaxError, decodeJson(Msg, deep_value, .{ .recursion_limit = 3 }));
    const deep_message = try nestedJson(gpa, 4, "{\"recursiveMessage\":", "{\"optionalValue\":[[1]]}", "}");
    defer gpa.free(deep_message);
    try testing.expectError(error.SyntaxError, decodeJson(Msg, deep_message, .{ .recursion_limit = 3 }));
}

test "malformed input: Duration JSON is digits only" {
    const gpa = testing.allocator;
    const Duration = protobuf.wkt.Duration;
    for ([_][]const u8{
        "\"0.+5s\"",
        "\"1_000s\"",
        "\"1.0_5s\"",
        "\"+5s\"",
        "\"+0.5s\"",
        "\"-.5s\"",
        "\".5s\"",
        "\"--1s\"",
        "\"1.-5s\"",
        "\"1.s\"",
        "\"s\"",
    }) |text| {
        if (Duration.jsonDecode(text, .{}, gpa)) |parsed| {
            parsed.deinit();
            std.debug.print("accepted {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    for ([_]struct { []const u8, i64, i32 }{
        .{ "\"3s\"", 3, 0 },
        .{ "\"-1.5s\"", -1, -500_000_000 },
        .{ "\"1.000000005s\"", 1, 5 },
        .{ "\"-0.5s\"", 0, -500_000_000 },
        .{ "\"315576000000s\"", 315576000000, 0 },
    }) |case| {
        const parsed = try Duration.jsonDecode(case[0], .{}, gpa);
        defer parsed.deinit();
        try testing.expectEqual(case[1], parsed.value.seconds);
        try testing.expectEqual(case[2], parsed.value.nanos);
    }
    // Seconds too long for an i64 fail rather than overflow.
    try testing.expectError(error.UnexpectedToken, Duration.jsonDecode("\"99999999999999999999999s\"", .{}, gpa));
}

test "malformed input: a scalar oneof member frees the member it replaces" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "\x0a\x01A", // string_in_oneof = "A"
        "\x12\x03\x12\x01x", // message_in_oneof = { str: "x" }
    }) |previous| {
        var buffer: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try w.writeAll(previous);
        try w.writeAll("\x18\x05"); // a_number = 5
        var reader: std.Io.Reader = .fixed(w.buffered());
        var msg = try tests_oneof.OneofContainer.decode(&reader, gpa);
        defer msg.deinit(gpa);
        try testing.expectEqual(5, msg.some_oneof.?.a_number);
    }
}

/// Counts the bytes requested from `child`, freed or not.
const CountingAllocator = struct {
    child: std.mem.Allocator = testing.allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total += len;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Extension 100 of `merge.Node`.
const merge_number = protobuf.Extension(merge.Node, ?i32, protobuf.fd(100, .{ .scalar = .int32 }), "tests.malformed.merge_number", null, .{});

/// Extension record 100 (a varint) and unknown field 50 (a varint) of value `v`.
inline fn rec(comptime v: u8) []const u8 {
    return "\xa0\x06" ++ .{v};
}
inline fn unk(comptime v: u8) []const u8 {
    return "\x90\x03" ++ .{v};
}
/// Field `tag` holding the message `fields`.
inline fn sub(comptime tag: u8, comptime fields: []const u8) []const u8 {
    return .{ tag, fields.len } ++ fields;
}

fn decodeNode(bytes: []const u8, options: protobuf.DecodeOptions) !merge.Node {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decodeWithOptions(merge.Node, &reader, testing.allocator, options);
}

fn expectRecords(msg: anytype, extensions: []const u8, unknown: []const u8) !void {
    try testing.expectEqualSlices(u8, extensions, msg._extensions.records);
    try testing.expectEqualSlices(u8, unknown, msg._unknown_fields);
}

test "malformed input: repeated submessages merge their records in order" {
    const gpa = testing.allocator;
    // Node fields: child 1, member 2 (oneof), number 3 (oneof), items 5,
    // leaf 7, leaf_member 8 (oneof).

    // A singular submessage, with records of the parent in between.
    {
        var msg = try decodeNode(sub(0x0a, rec(1) ++ unk(1)) ++ rec(9) ++ sub(0x0a, rec(2)) ++ unk(9) ++ sub(0x0a, unk(2) ++ rec(3)), .{});
        defer msg.deinit(gpa);
        try expectRecords(msg, rec(9), unk(9));
        try expectRecords(msg.child.?.*, rec(1) ++ rec(2) ++ rec(3), unk(1) ++ unk(2));
    }
    // Grandchildren merged across merges of their parent.
    {
        var msg = try decodeNode(sub(0x0a, sub(0x0a, rec(1))) ++ sub(0x0a, rec(7)) ++ sub(0x0a, sub(0x0a, rec(2) ++ unk(2))) ++ sub(0x0a, sub(0x0a, rec(3))), .{});
        defer msg.deinit(gpa);
        try expectRecords(msg.child.?.*, rec(7), "");
        try expectRecords(msg.child.?.child.?.*, rec(1) ++ rec(2) ++ rec(3), unk(2));
    }
    // An inline submessage.
    {
        var msg = try decodeNode(sub(0x3a, rec(1)) ++ sub(0x3a, rec(2) ++ unk(1)), .{});
        defer msg.deinit(gpa);
        try expectRecords(msg.leaf.?, rec(1) ++ rec(2), unk(1));
    }
    // Oneof members: a switch to another member starts over.
    {
        var msg = try decodeNode(sub(0x12, rec(1)) ++ sub(0x12, sub(0x0a, rec(2))) ++ "\x18\x05" ++ sub(0x12, rec(3)) ++ sub(0x12, sub(0x0a, rec(4))) ++ sub(0x12, rec(5)), .{});
        defer msg.deinit(gpa);
        try expectRecords(msg.choice.?.member.*, rec(3) ++ rec(5), "");
        try expectRecords(msg.choice.?.member.child.?.*, rec(4), "");
    }
    {
        var msg = try decodeNode(sub(0x42, rec(1)) ++ sub(0x42, rec(2)) ++ sub(0x12, sub(0x0a, rec(3))) ++ sub(0x42, rec(4)) ++ sub(0x42, unk(5)), .{});
        defer msg.deinit(gpa);
        try expectRecords(msg.choice.?.leaf_member, rec(4), unk(5));
    }
    // Elements of a repeated field stay apart, and merge within themselves.
    {
        var msg = try decodeNode(sub(0x2a, rec(1)) ++ sub(0x2a, sub(0x0a, rec(2)) ++ sub(0x0a, rec(3))) ++ sub(0x2a, rec(4)), .{});
        defer msg.deinit(gpa);
        try testing.expectEqual(3, msg.items.items.len);
        try expectRecords(msg.items.items[0], rec(1), "");
        try expectRecords(msg.items.items[1].child.?.*, rec(2) ++ rec(3), "");
        try expectRecords(msg.items.items[2], rec(4), "");
    }
    // Records from an earlier decode into the same message come first.
    {
        var msg = try decodeNode(sub(0x0a, rec(1)), .{});
        defer msg.deinit(gpa);
        const more = sub(0x0a, rec(2)) ++ sub(0x0a, rec(3));
        var reader: std.Io.Reader = .fixed(more);
        _ = try protobuf.wire.decodeMessage(&msg, gpa, &reader, .{});
        try expectRecords(msg.child.?.*, rec(1) ++ rec(2) ++ rec(3), "");
    }
    // Known extensions are validated once merged.
    {
        const registry: protobuf.ExtensionRegistry = .init(.{merge_number});
        var msg = try decodeNode(sub(0x0a, rec(1)) ++ sub(0x0a, rec(2)) ++ sub(0x0a, sub(0x0a, rec(3))) ++ sub(0x0a, sub(0x0a, rec(4))), .{ .extensions = &registry });
        defer msg.deinit(gpa);
        try testing.expectEqual(2, try merge_number.get(msg.child.?.*, gpa));
        try testing.expectEqual(4, try merge_number.get(msg.child.?.child.?.*, gpa));
        // Extension 100 holds a varint, not a length-delimited value.
        try testing.expectError(error.InvalidInput, decodeNode(sub(0x0a, rec(1)) ++ sub(0x0a, "\xa2\x06\x01A"), .{ .extensions = &registry }));
        try testing.expectError(error.InvalidInput, decodeNode(sub(0x0a, sub(0x0a, rec(1))) ++ sub(0x0a, sub(0x0a, "\xa2\x06\x01A")), .{ .extensions = &registry }));
    }
    // Failures past merges free everything.
    try testing.expectError(error.EndOfStream, decodeNode(sub(0x0a, rec(1)) ++ sub(0x0a, sub(0x0a, rec(2))) ++ sub(0x0a, sub(0x0a, rec(3))) ++ sub(0x12, rec(4)) ++ sub(0x12, rec(5)) ++ "\x0a\x05\xa0", .{}));
    try testing.expectError(error.InvalidInput, decodeNode(sub(0x0a, rec(1)) ++ sub(0x0a, sub(0x0a, rec(2))) ++ sub(0x0a, sub(0x0a, rec(3))) ++ "\x0a\x02\x0c\x00", .{}));
}

test "malformed input: repeated submessages merge in linear time" {
    const gpa = testing.allocator;
    const registry: protobuf.ExtensionRegistry = .init(.{merge_number});
    const reps = 20_000;
    inline for (.{
        .{ sub(0x0a, rec(0)), protobuf.DecodeOptions{} }, // child
        .{ sub(0x0a, rec(0)), protobuf.DecodeOptions{ .extensions = &registry } },
        .{ sub(0x0a, unk(0)), protobuf.DecodeOptions{} },
        .{ sub(0x0a, sub(0x0a, rec(0))), protobuf.DecodeOptions{} }, // grandchild
        .{ sub(0x3a, rec(0)), protobuf.DecodeOptions{} }, // inline leaf
        .{ sub(0x12, rec(0)), protobuf.DecodeOptions{} }, // oneof member
        .{ sub(0x12, sub(0x0a, rec(0))), protobuf.DecodeOptions{} },
    }) |case| {
        const input = try gpa.alloc(u8, reps * case[0].len);
        defer gpa.free(input);
        for (0..reps) |i| @memcpy(input[i * case[0].len ..][0..case[0].len], case[0]);

        var counting: CountingAllocator = .{};
        const allocator = counting.allocator();
        var reader: std.Io.Reader = .fixed(input);
        var msg = try protobuf.decodeWithOptions(merge.Node, &reader, allocator, case[1]);
        defer msg.deinit(allocator);
        if (counting.total > 32 * input.len) {
            std.debug.print("{d} bytes allocated for {d} bytes of input ({x})\n", .{ counting.total, input.len, case[0] });
            return error.TestUnexpectedResult;
        }
    }
}
