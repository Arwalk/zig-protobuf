const std = @import("std");
const testing = std.testing;
const generated = @import(".generated/source_protoc.pb.zig");
const google = @import(".generated/google/protobuf.pb.zig");

test "a custom option on descriptor.proto is generated" {
    try testing.expectEqualStrings("built from source", generated.Event._options.@"source_protoc.note");
}

test "a message with a well-known type round trips" {
    const event: generated.Event = .{
        .name = "launch",
        .at = google.Timestamp{ .seconds = 1234, .nanos = 5 },
    };

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try event.encode(&writer.writer, testing.allocator);

    var reader: std.Io.Reader = .fixed(writer.written());
    var decoded = try generated.Event.decode(&reader, testing.allocator);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqualStrings("launch", decoded.name);
    try testing.expectEqual(1234, decoded.at.?.seconds);
    try testing.expectEqual(5, decoded.at.?.nanos);
}
