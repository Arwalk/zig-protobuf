const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const vector_tile = @import("./generated/vector_tile.pb.zig");
const binaryFile = @embedFile("./fixtures/vector_tile.bin");

pub fn printAllDecoded(input: []const u8) !void {
    var iterator = protobuf.WireDecoderIterator{ .input = input };
    std.debug.print("Decoding: {s}\n", .{std.fmt.fmtSliceHexUpper(input)});
    while (try iterator.next()) |extracted_data| {
        std.debug.print("  {any}\n", .{extracted_data});
    }
}

test "mapbox decoding and re-encoding" {
    // first decode the binary
    const decoded = try vector_tile.Tile.decode(binaryFile, testing.allocator);
    defer decoded.deinit();

    // then encode it
    const encoded = try decoded.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    // then re-decode it
    const decoded2 = try vector_tile.Tile.decode(encoded, testing.allocator);
    defer decoded2.deinit();

    // finally assert
    try testing.expectEqualDeep(decoded, decoded2);
}
