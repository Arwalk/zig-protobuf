const std = @import("std");
const protobuf = @import("protobuf");
const mem = std.mem;
const Allocator = mem.Allocator;
const eql = mem.eql;
const fd = protobuf.fd;
const pb_decode = protobuf.pb_decode;
const pb_encode = protobuf.pb_encode;
const pb_deinit = protobuf.pb_deinit;
const pb_init = protobuf.pb_init;
const testing = std.testing;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const FieldType = protobuf.FieldType;
const tests = @import("./generated/tests.pb.zig");
const DefaultValues = @import("./generated/jspb/test.pb.zig").DefaultValues;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const selfref = @import("./generated/selfref.pb.zig");
const pblogs = @import("./generated/opentelemetry/proto/logs/v1.pb.zig");

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "DefaultValuesInit" {
    var demo = DefaultValues.init(testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}

test "DefaultValuesDecode" {
    var demo = try DefaultValues.decode("", testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?.getSlice());
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?.getSlice());
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?.getSlice());
}

test "issue #74" {
    var item = metrics.MetricsData.init(testing.allocator);
    var copy = try item.dupe(testing.allocator);
    copy.deinit();
    item.deinit();
}



const SelfRefNode = selfref.SelfRefNode;
const ManagedStruct = protobuf.ManagedStruct;

test "self ref test" {
    var demo = SelfRefNode.init(testing.allocator);
    var demo2 = SelfRefNode.init(testing.allocator);
    demo2.version = 1;
    demo.node = ManagedStruct(SelfRefNode).managed(&demo2);
    defer demo.deinit();

    try testing.expectEqual(@as(i32, 0), demo.version);
    const encoded = try demo.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 0x08, 0x01 }, encoded);

    const decoded = try SelfRefNode.decode(encoded, testing.allocator);
    defer decoded.deinit();

    // checking that reencoding a decoded message works
    const reencoded = try decoded.encode(testing.allocator);
    defer testing.allocator.free(reencoded);

    try testing.expectEqualSlices(u8, encoded, reencoded);

    try testing.expectEqual(@as(i32, 1), decoded.node.?.get().version);
}

test "self ref test with cycle, should fail" {
    var demo = SelfRefNode.init(testing.allocator);
    demo.node = ManagedStruct(SelfRefNode).managed(&demo);
    defer demo.deinit();

    try testing.expectError(protobuf.EncodingError.CycleInSelfReferencingMessage, demo.encode(testing.allocator));
}
