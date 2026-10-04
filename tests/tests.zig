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

    // Fields with explicit presence are unset until assigned...
    try std.testing.expectEqual(null, demo.string_field);
    try std.testing.expectEqual(null, demo.bool_field);
    try std.testing.expectEqual(null, demo.int_field);
    try std.testing.expectEqual(null, demo.enum_field);
    try std.testing.expectEqual(null, demo.empty_field);
    try std.testing.expectEqual(null, demo.bytes_field);

    // ...and their declared default values are exposed in `defaults`.
    const defaults = DefaultValues.defaults;
    try std.testing.expectEqualSlices(u8, "default<>'\"abc", defaults.string_field);
    try std.testing.expectEqual(true, defaults.bool_field);
    try std.testing.expectEqual(11, defaults.int_field);
    try std.testing.expectEqual(.E1, defaults.enum_field);
    try std.testing.expectEqualSlices(u8, "", defaults.empty_field);
    try std.testing.expectEqualSlices(u8, "moo", defaults.bytes_field);
}

test "DefaultValuesDecode" {
    var reader: std.Io.Reader = .fixed("");
    var demo = try DefaultValues.decode(&reader, std.testing.allocator);
    defer demo.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, demo.string_field);
    try std.testing.expectEqual(null, demo.bool_field);
    try std.testing.expectEqual(null, demo.int_field);
    try std.testing.expectEqual(null, demo.enum_field);
    try std.testing.expectEqual(null, demo.empty_field);
    try std.testing.expectEqual(null, demo.bytes_field);

    // Unset fields are not serialized, even though they have a default value.
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try demo.encode(&w.writer, std.testing.allocator);
    try std.testing.expectEqual(0, w.written().len);
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
