const std = @import("std");
const protobuf = @import("protobuf");
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
    var demo: DefaultValues = .{};
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try std.testing.expectEqual(true, demo.bool_field.?);
    try std.testing.expectEqual(demo.int_field, 11);
    try std.testing.expectEqual(demo.enum_field.?, .E1);
    try std.testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try std.testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "DefaultValuesDecode" {
    var reader: std.Io.Reader = .fixed("");
    var demo = try DefaultValues.decode(&reader, std.testing.allocator);
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "default<>'\"abc", demo.string_field.?);
    try std.testing.expectEqual(true, demo.bool_field.?);
    try std.testing.expectEqual(demo.int_field, 11);
    try std.testing.expectEqual(demo.enum_field.?, .E1);
    try std.testing.expectEqualSlices(u8, "", demo.empty_field.?);
    try std.testing.expectEqualSlices(u8, "moo", demo.bytes_field.?);
}

test "issue #74" {
    var item: metrics.MetricsData = .{};
    var copy = try item.dupe(std.testing.allocator);
    copy.deinit(std.testing.allocator);
    item.deinit(std.testing.allocator);
}

test "LogsData proto issue #84" {
    var logsData: pblogs.LogsData = .{};
    defer logsData.deinit(std.testing.allocator);

    var rl: pblogs.ResourceLogs = .{};
    defer rl.deinit(std.testing.allocator);

    try logsData.resource_logs.append(std.testing.allocator, rl);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try logsData.encode(&w.writer, std.testing.allocator); // <- compile error before
}

const SelfRefNode = selfref.SelfRefNode;

test "self ref test" {
    var demo: SelfRefNode = .{};
    const demo2 = try std.testing.allocator.create(SelfRefNode);
    demo2.* = .{};
    demo2.version = 1;
    demo.node = demo2;
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), demo.version);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try demo.encode(&w.writer, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 0x08, 0x01 }, w.written());

    var reader: std.Io.Reader = .fixed(w.written());
    var decoded = try SelfRefNode.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 1), decoded.node.?.version);
}

// TODO: check for cyclic structure
