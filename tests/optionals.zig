const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const proto3 = @import("./generated/protobuf_test_messages/proto3.pb.zig");
const longs = @import("./generated/tests/longs.pb.zig");
const jspb = @import("./generated/jspb/test.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const longName = @import("./generated/some/really/long/name/which/does/not/really/make/any/sense/but/sometimes/we/still/see/stuff/like/this.pb.zig");

test "empty string in optional fields must be serialized over the wire" {
    var t: jspb.TestClone = .{};
    defer t.deinit(std.testing.allocator);

    try testing.expect(t.str == null);

    // first encode with NULL
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try t.encode(&w.writer);
    try testing.expectEqualSlices(u8, "", w.written());

    // decoded must be null as well
    var reader: std.Io.Reader = .fixed("");
    var decodedNull = try jspb.TestClone.decode(&reader, testing.allocator);
    defer decodedNull.deinit(std.testing.allocator);
    try testing.expect(decodedNull.str == null);

    // setting a value to "" must serialize the value
    t.str = "";
    try testing.expect(t.str.?.len == 0);

    // then the encoded must be an empty string
    var w2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w2.deinit();
    try t.encode(&w2.writer);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x00 }, w2.written());

    // decoded must be null as well
    var reader2: std.Io.Reader = .fixed(w2.written());
    var decodedEmpty = try jspb.TestClone.decode(&reader2, testing.allocator);
    defer decodedEmpty.deinit(std.testing.allocator);
    try testing.expect(decodedEmpty.str.?.len == 0);
}

test "unittest.proto parse and re-encode" {
    const binary_file =
        "\x08\x65\x10\x66\x18\x67\x20\x68\x28\xd2\x01\x30\xd4\x01\x3d\x6b\x00\x00\x00\x41\x6c\x00" ++
        "\x00\x00\x00\x00\x00\x00\x4d\x6d\x00\x00\x00\x51\x6e\x00\x00\x00\x00\x00\x00\x00\x5d\x00" ++
        "\x00\xde\x42\x61\x00\x00\x00\x00\x00\x00\x5c\x40\x68\x01\x72\x03\x31\x31\x35\x7a\x03\x31" ++
        "\x31\x36\x83\x01\x88\x01\x75\x84\x01";

    var reader: std.Io.Reader = .fixed(binary_file);
    // first decode the binary
    var decoded = try unittest.TestAllTypes.decode(&reader, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try assert(decoded);

    // then encode it
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try decoded.encode(&w.writer);

    // then re-decode it
    var reader2: std.Io.Reader = .fixed(w.written());
    var decoded2 = try unittest.TestAllTypes.decode(&reader2, testing.allocator);
    defer decoded2.deinit(std.testing.allocator);

    var w2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w2.deinit();

    try decoded2.encode(&w2.writer);

    try assert(decoded2);

    // finally assert blackbox serialization
    try testing.expectEqualSlices(u8, w.written(), w2.written());
}

fn assert(decoded: unittest.TestAllTypes) !void {
    try testing.expectEqual(decoded.optional_int32, 101);
    try testing.expectEqual(decoded.optional_int64, 102);
    try testing.expectEqual(decoded.optional_uint32, 103);
    try testing.expectEqual(decoded.optional_uint64, 104);
    // TODO: review why this zigzag encoding is not working
    // TODO: try testing.expectEqual(decoded.optional_sint32, -53);
    // TODO: try testing.expectEqual(decoded.optional_sint64, -xxx);
    try testing.expectEqual(decoded.optional_fixed32, 107);
    try testing.expectEqual(decoded.optional_fixed64, @as(i64, 108));
    try testing.expectEqual(decoded.optional_sfixed32, 109);
    try testing.expectEqual(decoded.optional_sfixed64, @as(i64, 110));
    try testing.expectEqual(decoded.optional_float, 111.0);
    try testing.expectEqual(decoded.optional_double, 112.0);
    try testing.expectEqual(decoded.optional_bool, true);
    try testing.expectEqualSlices(u8, decoded.optional_string.?, "115");
    try testing.expectEqualSlices(u8, decoded.optional_bytes.?, "116");
}
