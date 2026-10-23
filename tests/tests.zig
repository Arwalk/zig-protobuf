const std = @import("std");
const protobuf = @import("protobuf");
const tests = @import("./generated/tests.pb.zig");
const DefaultValues = @import("./generated/jspb/test.pb.zig").DefaultValues;
const tests_oneof = @import("./generated/tests/oneof.pb.zig");
const metrics = @import("./generated/opentelemetry/proto/metrics/v1.pb.zig");
const selfref = @import("./generated/selfref.pb.zig");
const oneofselfref = @import("./generated/oneofselfref.pb.zig");
const unittest = @import("./generated/unittest.pb.zig");
const jspb = @import("./generated/jspb/test.pb.zig");
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

/// Checks that `bytes` decode as a `T` that encodes back to them, also once
/// duplicated and once through JSON, and merged with itself.
fn expectRoundTrips(comptime T: type, bytes: []const u8) !void {
    const gpa = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(bytes);
    var msg = try T.decode(&reader, gpa);
    defer msg.deinit(gpa);
    try expectEncodes(msg, bytes);

    var copy = try msg.dupe(gpa);
    defer copy.deinit(gpa);
    try expectEncodes(copy, bytes);

    const text = try msg.jsonEncode(.{}, .{}, gpa);
    defer gpa.free(text);
    const parsed = try T.jsonDecode(text, .{}, gpa);
    defer parsed.deinit();
    try expectEncodes(parsed.value, bytes);

    // The same message twice: the oneof member is merged.
    const twice = try std.mem.concat(gpa, u8, &.{ bytes, bytes });
    defer gpa.free(twice);
    var merged_reader: std.Io.Reader = .fixed(twice);
    var merged = try T.decode(&merged_reader, gpa);
    defer merged.deinit(gpa);
}

fn expectEncodes(msg: anytype, bytes: []const u8) !void {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try msg.encode(&w.writer, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, bytes, w.written());
}

test "self ref test: a oneof member of the message's own type" {
    // Tree { branch { branch { leaf: 7 } } }
    const bytes = "\x0a\x04\x0a\x02\x10\x07";
    try expectRoundTrips(oneofselfref.Tree, bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var tree = try oneofselfref.Tree.decode(&reader, std.testing.allocator);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(7, tree.kind.?.branch.kind.?.branch.kind.?.leaf);
}

test "self ref test: a cycle through a oneof and another message" {
    // Node { sub_node { sub { sub_node { another_string: "x" } } another_string: "y" } }
    const bytes = "\x0a\x0a" ++ "\x0a\x05\x0a\x03\x12\x01x" ++ "\x12\x01y";
    try expectRoundTrips(oneofselfref.Node, bytes);
    try expectRoundTrips(oneofselfref.Result, "\x08\x01\x12\x0c" ++ bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var node = try oneofselfref.Node.decode(&reader, std.testing.allocator);
    defer node.deinit(std.testing.allocator);
    const sub = node.node.?.sub_node;
    try std.testing.expectEqualStrings("y", sub.another_string);
    try std.testing.expectEqualStrings("x", sub.sub.?.node.?.sub_node.another_string);
}

test "self ref test: messages that hold each other" {
    // TestMutualRecursionA { bb { a { bb { optional_int32: 5 } } } sub_message { b { optional_int32: 1 } } }
    const bytes = "\x0a\x06\x0a\x04\x0a\x02\x10\x05" ++ "\x1a\x04\x0a\x02\x10\x01";
    try expectRoundTrips(unittest.TestMutualRecursionA, bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    var a = try unittest.TestMutualRecursionA.decode(&reader, std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(5, a.bb.?.a.?.bb.?.optional_int32);
    try std.testing.expectEqual(1, a.sub_message.?.b.?.optional_int32);

    // jspb's TestMessageWithOneof { rone { rtwo: "x" } }
    try expectRoundTrips(jspb.TestMessageWithOneof, "\x32\x03\x3a\x01x");
}
