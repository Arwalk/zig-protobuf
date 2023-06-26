const std = @import("std");
const testing = std.testing;

const protobuf = @import("protobuf");
const vector_tile = @import("./generated/vector_tile.pb.zig");
const binary_file = @embedFile("./fixtures/vector_tile.bin");

test "mapbox decoding and re-encoding" {
    // we will decode a releaseable copy of the binary file. to ensure that string slices are not
    // leaked into final string values
    var copied_slice = try testing.allocator.dupe(u8, binary_file);

    // first decode the binary
    const decoded = try vector_tile.Tile.decode(copied_slice, testing.allocator);
    defer decoded.deinit();

    // then encode it
    const encoded = try decoded.encode(testing.allocator);
    defer testing.allocator.free(encoded);

    // at this moment, the copied slice will be deallocated, if strings were not copied, the decoded2 value
    // should differ
    testing.allocator.free(copied_slice);

    // then re-decode it
    const decoded2 = try vector_tile.Tile.decode(encoded, testing.allocator);
    defer decoded2.deinit();

    // finally assert
    try testing.expectEqualDeep(decoded, decoded2);

    const encoded2 = try decoded2.encode(testing.allocator);
    defer testing.allocator.free(encoded2);
    try testing.expectEqualSlices(u8, encoded, encoded2);
}
