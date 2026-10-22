//! Decoding malformed input: each case must fail cleanly, without an
//! allocation sized by an unchecked length and without unbounded recursion.
const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const selfref = @import("./generated/selfref.pb.zig");
const ext = @import("./generated/tests/extensions.pb.zig");

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

test "malformed input: unknown groups nest at most recursion_limit deep" {
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
    const ok = try nestedGroups(gpa, protobuf.wire.recursion_limit - 1, 2);
    defer gpa.free(ok);
    try decodeCapped(tests.WithStrings, ok);
    const too_deep = try nestedGroups(gpa, protobuf.wire.recursion_limit + 1, 2);
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCapped(tests.WithStrings, too_deep));
}

/// A `SelfRefNode` nested `depth` deep, encoded.
fn nestedNodes(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, "\x08\x01"); // version = 1
    for (0..depth) |_| {
        var prefix: [11]u8 = undefined;
        var w: std.Io.Writer = .fixed(&prefix);
        w.writeByte(0x12) catch unreachable; // field 2, length-delimited
        w.writeUleb128(bytes.items.len) catch unreachable;
        try bytes.insertSlice(gpa, 0, w.buffered());
    }
    return bytes.toOwnedSlice(gpa);
}

test "malformed input: recursive messages nest at most recursion_limit deep" {
    const gpa = testing.allocator;
    const ok = try nestedNodes(gpa, protobuf.wire.recursion_limit);
    defer gpa.free(ok);
    try decodeCapped(selfref.SelfRefNode, ok);

    const too_deep = try nestedNodes(gpa, protobuf.wire.recursion_limit + 1);
    defer gpa.free(too_deep);
    try testing.expectError(error.InvalidInput, decodeCapped(selfref.SelfRefNode, too_deep));
}

test "malformed input: varints of unknown fields are at most 10 bytes" {
    // Field 100 (in Extendable's extension range): a length of 11 bytes,
    // then a varint of 11 bytes.
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, "\xa2\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01"));
    try testing.expectError(error.InvalidInput, decodeCapped(ext.Extendable, "\xa0\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01"));
    // Ten bytes are fine.
    try decodeCapped(ext.Extendable, "\xa0\x06" ++ "\xff\xff\xff\xff\xff\xff\xff\xff\xff" ++ "\x01");
}
