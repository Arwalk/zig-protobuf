const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const graphics = @import("./generated/graphics.pb.zig");
const binary_file = @embedFile("./fixtures/graphics.bin");

test "GraphicsDB" {
    // first decode the binary
    const decoded = try graphics.GraphicsDB.decode(binary_file, testing.allocator);
    defer decoded.deinit();

    // then encode it
    const encoded = try decoded.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    // then re-decode it
    const decoded2 = try graphics.GraphicsDB.decode(encoded, testing.allocator);
    defer decoded2.deinit();

    // finally assert equal objects
    try testing.expectEqualDeep(decoded, decoded2);

    // and equal encodings
    const encoded2 = try decoded2.encode(testing.allocator);
    defer testing.allocator.free(encoded2);
    try testing.expectEqualSlices(u8, encoded, encoded2);

    // var file = try std.fs.cwd().openFile("debug/graphics-out.bin", .{ .mode = .write_only });
    // defer file.close();

    // _ = try file.write(encoded);
}
