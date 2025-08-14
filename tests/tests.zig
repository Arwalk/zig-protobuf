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
    var demo = try DefaultValues.init(std.testing.allocator);
    defer demo.deinit(std.testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "DefaultValuesDecode" {
    var demo = try DefaultValues.decode("", testing.allocator);
    defer demo.deinit(std.testing.allocator);

    try testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try testing.expectEqual(true, demo.bool_field.?);
    try testing.expectEqual(demo.int_field, 11);
    try testing.expectEqual(demo.enum_field.?, .E1);
    try testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "issue #74" {
    var item = try metrics.MetricsData.init(testing.allocator);
    var copy = try item.dupe(testing.allocator);
    copy.deinit(std.testing.allocator);
    item.deinit(std.testing.allocator);
}

test "LogsData proto issue #84" {
    var logsData = try pblogs.LogsData.init(std.testing.allocator);
    defer logsData.deinit(std.testing.allocator);

    var rl = try pblogs.ResourceLogs.init(std.testing.allocator);
    defer rl.deinit(std.testing.allocator);

    try logsData.resource_logs.append(std.testing.allocator, rl);

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    const w = bytes.writer(std.testing.allocator);

    try logsData.encode(w.any(), std.testing.allocator); // <- compile error before
}

const SelfRefNode = selfref.SelfRefNode;
const ManagedStruct = protobuf.ManagedStruct;

//pub const SelfRefNode = struct {
//    version: i32 = 0,
//    node: ?ManagedStruct(SelfRefNode)= null,
//
//    pub const _desc_table = .{
//        .version = fd(1, .{ .Varint = .Simple }),
//        .node = fd(2, .{ .SubMessage = {} }),
//    };
//
//    pub usingnamespace protobuf.MessageMixins(@This());
//};

test "self ref test" {
    var demo = try SelfRefNode.init(testing.allocator);
    const demo2 = try std.testing.allocator.create(SelfRefNode);
    demo2.* = try SelfRefNode.init(testing.allocator);
    demo2.version = 1;
    demo.node = demo2;
    defer demo.deinit(std.testing.allocator);

    try testing.expectEqual(@as(i32, 0), demo.version);

    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    const w = encoded.writer(std.testing.allocator);

    try demo.encode(w.any(), std.testing.allocator);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 0x08, 0x01 }, encoded.items);

    var decoded = try SelfRefNode.decode(encoded.items, testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try testing.expectEqual(@as(i32, 1), decoded.node.?.version);
}

// TODO: check for cyclic structure
